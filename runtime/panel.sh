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

enable_bbr() {
  local previous_qdisc previous_cc managed
  managed="$(jq -r '.bbr.managed // false' "$NEKO_STATE")"

  if [[ "$managed" != "true" && -e "$SYSCTL_FILE" ]]; then
    die "${SYSCTL_FILE} 已存在但不是本工具创建的，拒绝覆盖。"
  fi

  previous_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  previous_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  modprobe sch_fq 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || die "当前内核没有可用的 tcp_bbr 模块。"

  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
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
  read -r -p "重置后旧订阅链接会立即失效，继续？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0

  new_token="$(random_urlsafe 24)"
  backup="$(mktemp "${NEKO_STATE}.backup.XXXXXX")"
  cp -a -- "$NEKO_STATE" "$backup"

  if atomic_json_update '.subscription.token = $token' --arg token "$new_token" \
    && render_all \
    && /usr/local/libexec/neko/caddy validate --config "${NEKO_CONFIG_DIR}/Caddyfile" --adapter caddyfile >/dev/null \
    && systemctl restart neko-caddy.service; then
    rm -f -- "$backup"
    ok "订阅链接已重置；旧链接不可再访问。"
    show_subscription_links
  else
    cp -a -- "$backup" "$NEKO_STATE"
    rm -f -- "$backup"
    render_all || true
    systemctl restart neko-caddy.service >/dev/null 2>&1 || true
    die "订阅重置失败，已恢复旧链接。"
  fi
}

uninstall_neko() {
  local answer created_user service
  printf '\n这会删除全部协议、证书、订阅和本工具创建的防火墙规则。\n'
  read -r -p "请输入 UNINSTALL 确认：" answer
  [[ "$answer" == "UNINSTALL" ]] || return 0

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
    /run/lock/neko-renew.lock
  rm -rf -- /etc/neko /var/lib/neko /usr/local/libexec/neko
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  if [[ "$created_user" == "true" ]] && id neko-proxy >/dev/null 2>&1; then
    userdel neko-proxy >/dev/null 2>&1 || true
    getent group neko-proxy >/dev/null 2>&1 && groupdel neko-proxy >/dev/null 2>&1 || true
  fi

  printf '\n[完成] 已卸载 Neko 创建的全部服务与数据。\n'
  exit 0
}

draw_menu() {
  clear 2>/dev/null || true
  printf 'Neko 终端控制面板\n'
  printf '=================\n'
  printf '0. 退出\n'
  printf '1. 查看三个订阅链接\n'
  printf '2. 开启 BBRv1\n'
  printf '3. 重置订阅链接（旧链接失效）\n'
  printf '4. 卸载全部协议\n\n'
}

main() {
  [[ -r "$NEKO_STATE" ]] || die "Neko 尚未完整安装。"
  while true; do
    draw_menu
    read -r -p "请选择 [0-4]：" choice
    case "$choice" in
      0) exit 0 ;;
      1) show_subscription_links ;;
      2) enable_bbr ;;
      3) rotate_subscription ;;
      4) uninstall_neko ;;
      *) warn "请输入 0 到 4。" ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回菜单……" _
  done
}

main "$@"
