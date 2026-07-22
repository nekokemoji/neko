#!/usr/bin/env bash

set -Eeuo pipefail

NEKO_ETC=/etc/neko
NEKO_VAR=/var/lib/neko
NEKO_LIBEXEC=/usr/local/libexec/neko
NEKO_SYSTEMD=/etc/systemd/system
NEKO_STATE=/etc/neko/state.json
NEKO_USER=neko-proxy
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- "$0" "$@"
  fi
  printf '[错误] neko 控制面板需要 root 权限。\n' >&2
  exit 1
fi

source /usr/local/libexec/neko/lib/common.sh
source /usr/local/libexec/neko/lib/render.sh
source /usr/local/libexec/neko/lib/firewall.sh

SYSCTL_FILE="/etc/sysctl.d/99-neko-bbr.conf"

acquire_maintenance_lock() {
  exec {MAINTENANCE_LOCK_FD}>/run/lock/neko-maintenance.lock
  flock -n "$MAINTENANCE_LOCK_FD" \
    || die "另一个 Neko 维护任务正在运行，请稍后重试。"
}

release_maintenance_lock() {
  flock -u "$MAINTENANCE_LOCK_FD" 2>/dev/null || true
  exec {MAINTENANCE_LOCK_FD}>&-
}

validate_runtime_configs() {
  /usr/local/libexec/neko/sing-box check -c "${NEKO_CONFIG_DIR}/sing-box.json" >/dev/null
  /usr/local/libexec/neko/xray run -test -c "${NEKO_CONFIG_DIR}/xray.json" >/dev/null
  /usr/local/libexec/neko/caddy validate \
    --config "${NEKO_CONFIG_DIR}/Caddyfile" --adapter caddyfile >/dev/null
}

restart_runtime_services() {
  local service
  systemctl restart \
    neko-caddy.service neko-sing-box.service neko-xray.service neko-hysteria.service
  sleep 1
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl is-active --quiet "${service}.service" || return 1
  done
}

enable_bbr() {
  local previous_qdisc previous_cc managed available_cc
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"

  if [[ "$managed" != "true" && -e "$SYSCTL_FILE" ]]; then
    die "${SYSCTL_FILE} 已存在但不是本工具创建的，拒绝覆盖。"
  fi

  previous_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  previous_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  modprobe sch_fq 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || die "当前内核没有可用的 tcp_bbr 模块。"

  available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<< "$available_cc"; then
    die "当前内核没有公布 bbr 拥塞控制算法。"
  fi

  if [[ "$managed" != "true" ]]; then
    atomic_json_update \
      '.bbr = {managed: true, previous_qdisc: $qdisc, previous_congestion_control: $cc}' \
      --arg qdisc "$previous_qdisc" --arg cc "$previous_cc"
  fi

  local tmp
  tmp="$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")"
  cat > "$tmp" <<'EOF'
# Managed by Neko. Removed, and previous live values restored, on uninstall.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE"

  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
    || die "BBR 配置写入后未生效。"
  ok "已启用内核 tcp_bbr（通常称 BBRv1；具体实现由发行版内核决定）。"
}

restore_bbr() {
  [[ -r "$NEKO_STATE" ]] || return 0
  local managed previous_qdisc previous_cc
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"
  [[ "$managed" == "true" ]] || return 0
  previous_qdisc="$(jq -r '.bbr.previous_qdisc // empty' "$NEKO_STATE")"
  previous_cc="$(jq -r '.bbr.previous_congestion_control // empty' "$NEKO_STATE")"
  rm -f -- "$SYSCTL_FILE"
  [[ -z "$previous_qdisc" ]] || sysctl -w "net.core.default_qdisc=${previous_qdisc}" >/dev/null 2>&1 || true
  [[ -z "$previous_cc" ]] || sysctl -w "net.ipv4.tcp_congestion_control=${previous_cc}" >/dev/null 2>&1 || true
}

rotate_subscription() {
  local answer new_token backup
  printf '此操作只让旧下载 URL 失效，不会撤销已经导入客户端的节点凭据。\n'
  read -r -p "继续重置六个订阅 URL？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  acquire_maintenance_lock
  new_token="$(random_urlsafe 24)"
  backup="$(mktemp "${NEKO_STATE}.backup.XXXXXX")"
  cp -a -- "$NEKO_STATE" "$backup"

  if atomic_json_update '.subscription.token = $token' --arg token "$new_token" \
    && render_all \
    && validate_runtime_configs \
    && systemctl restart neko-caddy.service; then
    rm -f -- "$backup"
    release_maintenance_lock
    ok "六个订阅 URL 已重置；旧 URL 不可再访问。"
    show_subscription_links
  else
    cp -a -- "$backup" "$NEKO_STATE"
    rm -f -- "$backup"
    render_all || true
    systemctl restart neko-caddy.service >/dev/null 2>&1 || true
    die "订阅重置失败，已恢复旧链接。"
  fi
}

refresh_subscription_endpoints() {
  local answer backup
  read -r -p "重新解析严格 IPv4/IPv6 地址并更新六份订阅？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  acquire_maintenance_lock
  load_state
  check_strict_dual_stack_dns "$DOMAIN"
  assert_strict_addresses_local
  backup="$(mktemp "${NEKO_STATE}.backup.XXXXXX")"
  cp -a -- "$NEKO_STATE" "$backup"

  if atomic_json_update \
      '.subscription.ipv4_domain = $v4_domain
       | .subscription.ipv6_domain = $v6_domain
       | .subscription.ipv4_address = $v4_address
       | .subscription.ipv6_address = $v6_address' \
      --arg v4_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
      --arg v6_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
      --arg v4_address "$SUBSCRIPTION_IPV4_ADDRESS" \
      --arg v6_address "$SUBSCRIPTION_IPV6_ADDRESS" \
    && render_all \
    && validate_runtime_configs \
    && restart_runtime_services; then
    rm -f -- "$backup"
    release_maintenance_lock
    ok "严格 IPv4/IPv6 端点与六份订阅已刷新。"
    show_subscription_links
  else
    cp -a -- "$backup" "$NEKO_STATE"
    rm -f -- "$backup"
    render_all || true
    restart_runtime_services >/dev/null 2>&1 || true
    die "端点刷新失败，已恢复原地址和订阅。"
  fi
}

uninstall_neko() {
  local answer created_user service
  printf '\n这会删除全部协议、证书、订阅和本工具创建的防火墙规则。\n'
  read -r -p "请输入 UNINSTALL 确认：" answer
  [[ "$answer" == "UNINSTALL" ]] || return 0

  acquire_maintenance_lock
  created_user="$(jq -r '.system_user_created // false' "$NEKO_STATE" 2>/dev/null || printf false)"
  systemctl disable --now neko-renew.timer >/dev/null 2>&1 || true
  systemctl stop neko-renew.service >/dev/null 2>&1 || true
  systemctl disable --now \
    neko-hysteria.service neko-xray.service neko-sing-box.service neko-caddy.service \
    >/dev/null 2>&1 || true
  systemctl stop \
    neko-hysteria.service neko-xray.service neko-sing-box.service neko-caddy.service \
    >/dev/null 2>&1 || true
  for service in neko-renew neko-hysteria neko-xray neko-sing-box neko-caddy; do
    if systemctl is-active --quiet "${service}.service"; then
      die "${service} 未能停止；为避免残留进程和端口跳跃规则，暂不删除文件。"
    fi
  done
  remove_firewall
  restore_bbr

  rm -f -- \
    /etc/systemd/system/neko-caddy.service \
    /etc/systemd/system/neko-sing-box.service \
    /etc/systemd/system/neko-xray.service \
    /etc/systemd/system/neko-hysteria.service \
    /etc/systemd/system/neko-renew.service \
    /etc/systemd/system/neko-renew.timer \
    /usr/local/bin/neko \
    /run/lock/neko-install.lock \
    /run/lock/neko-maintenance.lock
  rm -rf -- /etc/neko /var/lib/neko /usr/local/libexec/neko
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  if [[ "$created_user" == "true" ]] && id neko-proxy >/dev/null 2>&1; then
    userdel neko-proxy >/dev/null 2>&1 || true
    if getent group neko-proxy >/dev/null 2>&1; then
      groupdel neko-proxy >/dev/null 2>&1 || true
    fi
  fi

  printf '\n[完成] 已卸载 Neko 创建的全部服务与数据。\n'
  exit 0
}

draw_menu() {
  clear 2>/dev/null || true
  printf 'Neko 终端控制面板\n'
  printf '=================\n'
  printf '0. 退出\n'
  printf '1. 查看六个严格订阅链接\n'
  printf '2. 开启 BBRv1\n'
  printf '3. 重置订阅 URL（不会撤销已导入节点）\n'
  printf '4. 刷新严格 IPv4/IPv6 端点\n'
  printf '5. 卸载全部协议\n\n'
}

main() {
  [[ -r "$NEKO_STATE" ]] || die "Neko 尚未完整安装。"
  while true; do
    draw_menu
    read -r -p "请选择 [0-5]：" choice
    case "$choice" in
      0) exit 0 ;;
      1) show_subscription_links ;;
      2) enable_bbr ;;
      3) rotate_subscription ;;
      4) refresh_subscription_endpoints ;;
      5) uninstall_neko ;;
      *) warn "请输入 0 到 5。" ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回菜单……" _
  done
}

main "$@"
