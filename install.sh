#!/usr/bin/env bash

set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths are intentionally fixed.  This also keeps uninstall scoped.
NEKO_ETC=/etc/neko
NEKO_VAR=/var/lib/neko
NEKO_LIBEXEC=/usr/local/libexec/neko
NEKO_SYSTEMD=/etc/systemd/system
NEKO_STATE=/etc/neko/state.json
NEKO_USER=neko-proxy
NEKO_WORK_BASE=/var/tmp
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"
# shellcheck source=lib/firewall.sh
source "$SCRIPT_DIR/lib/firewall.sh"

DOMAIN_INPUT=""
EMAIL_INPUT=""
ACME_METHOD_INPUT=""
CLOUDFLARE_TOKEN_SOURCE_FILE=""
CLOUDFLARE_DNS_TOKEN_INPUT=""
ASSUME_YES=0
WORKDIR=""
ROLLBACK_NEEDED=0
CREATED_USER=0

usage() {
  cat <<EOF
用法：sudo bash install.sh [选项]

  --domain example.com     必填域名（不提供时交互询问）
  --email admin@example.com  ACME 账户邮箱
  --acme-method METHOD     http-01 或 cloudflare-dns-01
  --cloudflare-token-file FILE
                           从文件读取受限 Cloudflare API Token；不要把 Token 放在命令行
  --yes                    接受确认提示（仍会执行域名与证书硬校验）
  -h, --help               显示帮助
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --domain)
        (( $# >= 2 )) || die "--domain 缺少值。"
        DOMAIN_INPUT="$2"
        shift 2
        ;;
      --email)
        (( $# >= 2 )) || die "--email 缺少值。"
        EMAIL_INPUT="$2"
        shift 2
        ;;
      --acme-method)
        (( $# >= 2 )) || die "--acme-method 缺少值。"
        ACME_METHOD_INPUT="$2"
        shift 2
        ;;
      --cloudflare-token-file)
        (( $# >= 2 )) || die "--cloudflare-token-file 缺少值。"
        CLOUDFLARE_TOKEN_SOURCE_FILE="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知选项：$1"
        ;;
    esac
  done
}

assert_clean_target() {
  local path unit
  for path in \
    /etc/neko \
    /var/lib/neko \
    /usr/local/libexec/neko \
    /usr/local/bin/neko \
    /etc/systemd/system/neko-caddy.service \
    /etc/systemd/system/neko-sing-box.service \
    /etc/systemd/system/neko-xray.service \
    /etc/systemd/system/neko-hysteria.service \
    /etc/systemd/system/neko-renew.service \
    /etc/systemd/system/neko-renew.timer \
    /etc/firewalld/services/neko-proxy.xml \
    /etc/ufw/applications.d/neko-proxy; do
    [[ ! -e "$path" && ! -L "$path" ]] || die "目标已存在，为保护现有数据不会覆盖：${path}"
  done
  ! id "$NEKO_USER" >/dev/null 2>&1 || die "系统用户 ${NEKO_USER} 已存在，不会复用。"
  ! getent group "$NEKO_USER" >/dev/null 2>&1 || die "系统组 ${NEKO_USER} 已存在，不会复用。"
  for unit in \
    neko-caddy.service neko-sing-box.service neko-xray.service \
    neko-hysteria.service neko-renew.service neko-renew.timer; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      die "systemd 已存在同名单元，不会覆盖：${unit}"
    fi
  done
}

cleanup_failed_install() {
  set +e
  warn "安装未完成，正在回滚本次创建的内容……"
  systemctl disable --now neko-renew.timer >/dev/null 2>&1
  systemctl disable --now \
    neko-hysteria.service neko-xray.service neko-sing-box.service neko-caddy.service \
    >/dev/null 2>&1
  [[ -r "$NEKO_STATE" ]] && remove_firewall
  rm -f -- \
    /etc/systemd/system/neko-caddy.service \
    /etc/systemd/system/neko-sing-box.service \
    /etc/systemd/system/neko-xray.service \
    /etc/systemd/system/neko-hysteria.service \
    /etc/systemd/system/neko-renew.service \
    /etc/systemd/system/neko-renew.timer \
    /usr/local/bin/neko
  rm -rf -- /etc/neko /var/lib/neko /usr/local/libexec/neko
  systemctl daemon-reload >/dev/null 2>&1
  if (( CREATED_USER == 1 )) && id "$NEKO_USER" >/dev/null 2>&1; then
    userdel "$NEKO_USER" >/dev/null 2>&1
    getent group "$NEKO_USER" >/dev/null 2>&1 && groupdel "$NEKO_USER" >/dev/null 2>&1
  fi
}

finish() {
  local rc=$?
  trap - EXIT
  close_temporary_http_challenge_port
  if (( rc != 0 && ROLLBACK_NEEDED == 1 )); then
    cleanup_failed_install
  fi
  if [[ -n "$WORKDIR" && "$WORKDIR" == /var/tmp/neko-install.* && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  fi
  exit "$rc"
}

trap finish EXIT

collect_acme_settings() {
  local choice token_source_count=0

  [[ -z "$CLOUDFLARE_TOKEN_SOURCE_FILE" ]] \
    || ((token_source_count += 1))
  [[ -z "${CF_DNS_API_TOKEN_FILE:-}" ]] \
    || ((token_source_count += 1))
  [[ -z "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]] \
    || ((token_source_count += 1))
  [[ -z "${CF_DNS_API_TOKEN:-}" ]] \
    || ((token_source_count += 1))
  [[ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ]] \
    || ((token_source_count += 1))
  (( token_source_count <= 1 )) \
    || die "检测到多个 Cloudflare Token 来源；请只保留一种。"

  if [[ -z "$ACME_METHOD_INPUT" ]]; then
    if (( token_source_count == 1 )); then
      ACME_METHOD="$ACME_METHOD_CLOUDFLARE"
    elif [[ -t 0 ]]; then
      printf '\n证书验证方式：\n'
      printf '  1. Cloudflare DNS-01（推荐，不依赖 IPv6 HTTP 入站；需要受限 API Token）\n'
      printf '  2. HTTP-01（无需 Token；要求 Let\x27s Encrypt 所有验证节点均能访问双栈 TCP 80）\n'
      read -r -p "请选择 [1]：" choice
      case "$choice" in
        ""|1) ACME_METHOD="$ACME_METHOD_CLOUDFLARE" ;;
        2) ACME_METHOD="$ACME_METHOD_HTTP" ;;
        *) die "无效的证书验证方式选择：${choice}" ;;
      esac
    else
      die "非交互安装必须显式提供 --acme-method；不会自动选择依赖公网 TCP 80 的 HTTP-01。"
    fi
  else
    ACME_METHOD="$(normalize_acme_method "$ACME_METHOD_INPUT")" \
      || die "不支持的 --acme-method：${ACME_METHOD_INPUT}"
  fi

  if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
    (( token_source_count == 0 )) \
      || die "HTTP-01 模式不应提供 Cloudflare Token。"
    return 0
  fi

  if [[ -n "$CLOUDFLARE_TOKEN_SOURCE_FILE" ]]; then
    [[ -f "$CLOUDFLARE_TOKEN_SOURCE_FILE" && -r "$CLOUDFLARE_TOKEN_SOURCE_FILE" ]] \
      || die "Cloudflare Token 文件不可读：${CLOUDFLARE_TOKEN_SOURCE_FILE}"
    CLOUDFLARE_DNS_TOKEN_INPUT="$(<"$CLOUDFLARE_TOKEN_SOURCE_FILE")"
  elif [[ -n "${CF_DNS_API_TOKEN_FILE:-}" ]]; then
    [[ -f "$CF_DNS_API_TOKEN_FILE" && -r "$CF_DNS_API_TOKEN_FILE" ]] \
      || die "CF_DNS_API_TOKEN_FILE 不可读：${CF_DNS_API_TOKEN_FILE}"
    CLOUDFLARE_DNS_TOKEN_INPUT="$(<"$CF_DNS_API_TOKEN_FILE")"
  elif [[ -n "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]]; then
    [[ -f "$CLOUDFLARE_DNS_API_TOKEN_FILE" && -r "$CLOUDFLARE_DNS_API_TOKEN_FILE" ]] \
      || die "CLOUDFLARE_DNS_API_TOKEN_FILE 不可读：${CLOUDFLARE_DNS_API_TOKEN_FILE}"
    CLOUDFLARE_DNS_TOKEN_INPUT="$(<"$CLOUDFLARE_DNS_API_TOKEN_FILE")"
  elif [[ -n "${CF_DNS_API_TOKEN:-}" ]]; then
    CLOUDFLARE_DNS_TOKEN_INPUT="$CF_DNS_API_TOKEN"
  elif [[ -n "${CLOUDFLARE_DNS_API_TOKEN:-}" ]]; then
    CLOUDFLARE_DNS_TOKEN_INPUT="$CLOUDFLARE_DNS_API_TOKEN"
  elif [[ -t 0 ]]; then
    printf 'Token 需要 Zone/Zone/Read 与 Zone/DNS/Edit，并仅限当前域名所在的 zone。\n'
    read -r -s -p "请粘贴 Cloudflare API Token（输入不会显示）：" \
      CLOUDFLARE_DNS_TOKEN_INPUT
    printf '\n'
  else
    die "Cloudflare DNS-01 非交互安装必须提供 --cloudflare-token-file。"
  fi

  validate_cloudflare_dns_token "$CLOUDFLARE_DNS_TOKEN_INPUT" \
    || die "Cloudflare API Token 格式无效。"
  unset \
    CF_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN \
    CF_DNS_API_TOKEN_FILE CLOUDFLARE_DNS_API_TOKEN_FILE
}

collect_identity() {
  local answer
  if [[ -z "$DOMAIN_INPUT" ]]; then
    [[ -t 0 ]] || die "非交互安装必须提供 --domain；没有域名绝不继续。"
    read -r -p "请输入已解析到本机的域名：" DOMAIN_INPUT
  fi
  DOMAIN_INPUT="${DOMAIN_INPUT,,}"
  validate_domain "$DOMAIN_INPUT" || die "域名格式无效：${DOMAIN_INPUT}"

  if [[ -z "$EMAIL_INPUT" ]]; then
    if [[ -t 0 && $ASSUME_YES -eq 0 ]]; then
      read -r -p "ACME 邮箱 [admin@${DOMAIN_INPUT}]：" EMAIL_INPUT
    fi
    EMAIL_INPUT="${EMAIL_INPUT:-admin@${DOMAIN_INPUT}}"
  fi
  validate_email "$EMAIL_INPUT" || die "邮箱格式无效：${EMAIL_INPUT}"

  DOMAIN="$DOMAIN_INPUT"
  ACME_EMAIL="$EMAIL_INPUT"
  export DOMAIN ACME_EMAIL

  check_strict_dual_stack_dns "$DOMAIN"
  collect_acme_settings
  if (( ASSUME_YES == 0 )); then
    printf '\n基础域名：%s\nIPv4 订阅域名：%s\nIPv6 订阅域名：%s\n邮箱：%s\n证书验证：%s\n' \
      "$DOMAIN" "$SUBSCRIPTION_DOMAIN_IPV4" "$SUBSCRIPTION_DOMAIN_IPV6" \
      "$ACME_EMAIL" "$ACME_METHOD"
    if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
      printf '安装会用 Let\x27s Encrypt HTTP-01 验证三个域名，并占用 TCP 80/443。\n'
    else
      printf '安装会用 Cloudflare DNS-01 验证三个域名；受限 Token 将以 root-only 文件保存供续期。\n'
    fi
    read -r -p "确认三个域名均为 DNS only、直连本机并接受 ACME 服务条款？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "用户取消。"
  fi
}

assert_work_space() {
  local available_kib minimum_kib=$((768 * 1024))

  [[ -d "$NEKO_WORK_BASE" && -w "$NEKO_WORK_BASE" ]] || \
    die "临时工作目录不可写：${NEKO_WORK_BASE}"
  available_kib="$(df -Pk "$NEKO_WORK_BASE" | awk 'NR == 2 {print $4}')"
  [[ "$available_kib" =~ ^[0-9]+$ ]] || \
    die "无法读取 ${NEKO_WORK_BASE} 的剩余空间。"
  (( available_kib >= minimum_kib )) || \
    die "${NEKO_WORK_BASE} 剩余空间不足：至少需要 768 MiB，当前约 $((available_kib / 1024)) MiB。"
}

download_release_binaries() {
  local xray_asset sing_asset hysteria_asset caddy_asset lego_asset
  if [[ "$ARCH" == "amd64" ]]; then
    xray_asset="Xray-linux-64.zip"
  else
    xray_asset="Xray-linux-arm64-v8a.zip"
  fi
  sing_asset="sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
  hysteria_asset="hysteria-linux-${ARCH}"
  caddy_asset="caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz"
  lego_asset="lego_v${LEGO_VERSION}_linux_${ARCH}.tar.gz"

  mkdir -p "$WORKDIR/downloads" "$WORKDIR/unpack" "$WORKDIR/bin"
  download_verified "Xray ${XRAY_VERSION}" \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${xray_asset}" \
    "$(sha_for_arch XRAY)" "$WORKDIR/downloads/xray.zip"
  download_verified "sing-box ${SING_BOX_VERSION}" \
    "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${sing_asset}" \
    "$(sha_for_arch SING_BOX)" "$WORKDIR/downloads/sing-box.tar.gz"
  download_verified "Hysteria ${HYSTERIA_VERSION}" \
    "https://github.com/apernet/hysteria/releases/download/app%2Fv${HYSTERIA_VERSION}/${hysteria_asset}" \
    "$(sha_for_arch HYSTERIA)" "$WORKDIR/downloads/hysteria"
  download_verified "Caddy ${CADDY_VERSION}" \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/${caddy_asset}" \
    "$(sha_for_arch CADDY)" "$WORKDIR/downloads/caddy.tar.gz"
  download_verified "lego ${LEGO_VERSION}" \
    "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/${lego_asset}" \
    "$(sha_for_arch LEGO)" "$WORKDIR/downloads/lego.tar.gz"

  unzip -q "$WORKDIR/downloads/xray.zip" -d "$WORKDIR/unpack/xray"
  tar --no-same-owner -xzf "$WORKDIR/downloads/sing-box.tar.gz" -C "$WORKDIR/unpack"
  mkdir -p "$WORKDIR/unpack/caddy" "$WORKDIR/unpack/lego"
  tar --no-same-owner -xzf "$WORKDIR/downloads/caddy.tar.gz" -C "$WORKDIR/unpack/caddy"
  tar --no-same-owner -xzf "$WORKDIR/downloads/lego.tar.gz" -C "$WORKDIR/unpack/lego"

  install -m 0755 "$WORKDIR/unpack/xray/xray" "$WORKDIR/bin/xray"
  install -m 0755 \
    "$WORKDIR/unpack/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" \
    "$WORKDIR/bin/sing-box"
  install -m 0755 "$WORKDIR/downloads/hysteria" "$WORKDIR/bin/hysteria"
  install -m 0755 "$WORKDIR/unpack/caddy/caddy" "$WORKDIR/bin/caddy"
  install -m 0755 "$WORKDIR/unpack/lego/lego" "$WORKDIR/bin/lego"

  # awk consumes the complete stream.  Using `head -n 1` here can close the
  # pipe early and make a healthy Go binary exit with SIGPIPE under pipefail
  # (observed on AlmaLinux 9).
  "$WORKDIR/bin/xray" version 2>&1 | awk 'NR == 1 { print }'
  "$WORKDIR/bin/sing-box" version 2>&1 | awk 'NR == 1 { print }'
  "$WORKDIR/bin/hysteria" version 2>&1 | awk 'NR == 1 { print }'
  "$WORKDIR/bin/caddy" version
  "$WORKDIR/bin/lego" --version
}

issue_initial_certificate() {
  local acme_log="" acme_rc=0
  ROLLBACK_NEEDED=1
  install -d -m 0700 "$NEKO_VAR" "$NEKO_VAR/lego"
  if [[ "$ACME_METHOD" == "$ACME_METHOD_CLOUDFLARE" ]]; then
    info "使用 Cloudflare DNS-01 申请三个域名的 SAN 证书；不依赖 IPv6 HTTP 入站。"
    write_cloudflare_dns_token "$CLOUDFLARE_DNS_TOKEN_INPUT"
    CLOUDFLARE_DNS_TOKEN_INPUT=""
  else
    info "使用 HTTP-01 申请三个域名的 SAN 证书；失败时安装会停止并回滚。"
    open_temporary_http_challenge_port
    warn "请确认云安全组也已为 IPv4 与 IPv6 放行 TCP 80；脚本只能管理本机防火墙。"
  fi

  if [[ "$ACME_METHOD" == "$ACME_METHOD_HTTP" ]]; then
    acme_log="$WORKDIR/http-01.log"
    set +e
    run_lego_acme "$WORKDIR/bin/lego" standalone run \
      --path "$NEKO_VAR/lego" \
      --email "$ACME_EMAIL" \
      --domains "$DOMAIN" \
      --domains "$SUBSCRIPTION_DOMAIN_IPV4" \
      --domains "$SUBSCRIPTION_DOMAIN_IPV6" \
      --accept-tos \
      --key-type EC256 2>&1 | tee "$acme_log"
    acme_rc=${PIPESTATUS[0]}
    set -e
    close_temporary_http_challenge_port
    if (( acme_rc != 0 )); then
      explain_http01_failure "$acme_log"
      return "$acme_rc"
    fi
    rm -f -- "$acme_log"
  else
    run_lego_acme "$WORKDIR/bin/lego" standalone run \
      --path "$NEKO_VAR/lego" \
      --email "$ACME_EMAIL" \
      --domains "$DOMAIN" \
      --domains "$SUBSCRIPTION_DOMAIN_IPV4" \
      --domains "$SUBSCRIPTION_DOMAIN_IPV6" \
      --accept-tos \
      --key-type EC256
  fi

  CERT_FILE="$NEKO_VAR/lego/certificates/${DOMAIN}.crt"
  KEY_FILE="$NEKO_VAR/lego/certificates/${DOMAIN}.key"
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || die "ACME 返回成功但证书文件不存在。"
  openssl x509 -in "$CERT_FILE" -noout -checkend 2592000 >/dev/null \
    || die "取得的证书有效期不足 30 天。"
  local certificate_domain
  for certificate_domain in \
    "$DOMAIN" "$SUBSCRIPTION_DOMAIN_IPV4" "$SUBSCRIPTION_DOMAIN_IPV6"; do
    openssl x509 -in "$CERT_FILE" -noout -checkhost "$certificate_domain" >/dev/null \
      || die "取得的证书不包含 ${certificate_domain}。"
  done
  ok "三个域名验证与证书申请成功。"
}

explain_http01_failure() {
  local log_file="$1"

  if grep -Eqi \
    'secondary validation.*(network unreachable|no route to host)|(network unreachable|no route to host).*secondary validation' \
    "$log_file"; then
    warn "HTTP-01 日志显示外部验证节点无法经网络到达 VPS。若失败的是 IPv6 域名，通常表示云厂商或上游的 IPv6 路由不完整；脚本无法修复公网路由。"
    warn "建议重新安装并选择 1（Cloudflare DNS-01），或先让 VPS 商家修复 IPv6 入站路由。"
  elif grep -Eqi \
    'timeout during connect|connection timed out|connection refused|dial tcp.*timeout' \
    "$log_file"; then
    warn "HTTP-01 日志显示 TCP 80 无法从公网连入。请检查云安全组、商家防火墙和自定义 nftables/iptables 规则。"
    warn "不想维护公网 TCP 80 时，建议重新安装并选择 1（Cloudflare DNS-01）。"
  else
    warn "HTTP-01 验证失败。请根据上方 lego 原始错误检查 DNS、TCP 80 和公网 IPv4/IPv6 可达性。"
    warn "脚本不会自动切换验证方式；可重新安装并选择 1（Cloudflare DNS-01）。"
  fi
}

create_service_user_and_dirs() {
  local nologin_shell
  nologin_shell="$(command -v nologin || printf '/usr/sbin/nologin')"
  useradd --system --user-group --home-dir "$NEKO_VAR" --no-create-home \
    --shell "$nologin_shell" --comment "Neko proxy services" "$NEKO_USER"
  CREATED_USER=1

  install -d -m 0750 -o root -g "$NEKO_USER" "$NEKO_VAR"
  install -d -m 0750 -o root -g "$NEKO_USER" \
    "$NEKO_ETC" "$NEKO_ETC/config" "$NEKO_ETC/subscriptions"
  # setgid makes lego's root-created HTTP-01 challenge files inherit the
  # service group, so the unprivileged Caddy process can serve them.
  install -d -m 2750 -o root -g "$NEKO_USER" "$NEKO_VAR/acme"
  install -d -m 0755 -o root -g root "$NEKO_LIBEXEC" "$NEKO_LIBEXEC/lib"
  install -d -m 0750 -o "$NEKO_USER" -g "$NEKO_USER" \
    "$NEKO_VAR/caddy" "$NEKO_VAR/caddy/data" "$NEKO_VAR/caddy/config"

  if [[ -d "$NEKO_VAR/credentials" ]]; then
    chown root:root "$NEKO_VAR/credentials"
    chmod 0700 "$NEKO_VAR/credentials"
    if [[ -f "$CLOUDFLARE_DNS_TOKEN_FILE" ]]; then
      chown root:root "$CLOUDFLARE_DNS_TOKEN_FILE"
      chmod 0600 "$CLOUDFLARE_DNS_TOKEN_FILE"
    fi
  fi

  chown -R root:root "$NEKO_VAR/lego"
  find "$NEKO_VAR/lego" -type d -exec chmod 0700 {} +
  find "$NEKO_VAR/lego" -type f -exec chmod 0600 {} +
  chown "root:${NEKO_USER}" "$NEKO_VAR/lego"
  chmod 0750 "$NEKO_VAR/lego"
  chown -R "root:${NEKO_USER}" "$NEKO_VAR/lego/certificates"
  find "$NEKO_VAR/lego/certificates" -type d -exec chmod 0750 {} +
  find "$NEKO_VAR/lego/certificates" -type f -exec chmod 0640 {} +
}

install_payload() {
  install -m 0755 "$WORKDIR/bin/xray" "$NEKO_LIBEXEC/xray"
  install -m 0755 "$WORKDIR/bin/sing-box" "$NEKO_LIBEXEC/sing-box"
  install -m 0755 "$WORKDIR/bin/hysteria" "$NEKO_LIBEXEC/hysteria"
  install -m 0755 "$WORKDIR/bin/caddy" "$NEKO_LIBEXEC/caddy"
  install -m 0755 "$WORKDIR/bin/lego" "$NEKO_LIBEXEC/lego"
  install -m 0644 "$SCRIPT_DIR/versions.env" "$NEKO_LIBEXEC/versions.env"
  install -m 0644 "$SCRIPT_DIR/lib/common.sh" "$NEKO_LIBEXEC/lib/common.sh"
  install -m 0644 "$SCRIPT_DIR/lib/render.sh" "$NEKO_LIBEXEC/lib/render.sh"
  install -m 0644 "$SCRIPT_DIR/lib/firewall.sh" "$NEKO_LIBEXEC/lib/firewall.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/panel.sh" "$NEKO_LIBEXEC/panel.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/renew.sh" "$NEKO_LIBEXEC/renew.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh"
  ln -s "$NEKO_LIBEXEC/panel.sh" /usr/local/bin/neko

  local unit
  for unit in \
    neko-caddy.service neko-sing-box.service neko-xray.service \
    neko-hysteria.service neko-renew.service neko-renew.timer; do
    install -m 0644 "$SCRIPT_DIR/systemd/$unit" "$NEKO_SYSTEMD/$unit"
  done
}

generate_reality_pair() {
  local output private_key public_key
  output="$("$WORKDIR/bin/xray" x25519)"
  private_key="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<< "$output")"
  public_key="$(awk -F': ' '/^Password \(PublicKey\):/ {print $2}' <<< "$output")"
  [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "无法解析 REALITY 私钥。"
  [[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "无法解析 REALITY 公钥。"
  printf '%s %s\n' "$private_key" "$public_key"
}

write_initial_state() {
  local hy2_password hy2_obfs_password tuic_uuid tuic_password ss_password
  local anytls_password vision_uuid xhttp_uuid vision_pair xhttp_pair
  local vision_private vision_public xhttp_private xhttp_public
  local vision_sid xhttp_sid xhttp_path sub_token installed_at listen_address
  local HY2_START HY2_END TUIC_PORT SS_PORT ANYTLS_PORT VISION_PORT XHTTP_PORT

  initialize_port_reservations
  reserve_random_range 128 HY2_START HY2_END
  reserve_random_port TUIC_PORT
  reserve_random_port SS_PORT
  reserve_random_port ANYTLS_PORT
  reserve_random_port VISION_PORT
  reserve_random_port XHTTP_PORT

  hy2_password="$(random_urlsafe 24)"
  hy2_obfs_password="$(random_urlsafe 24)"
  tuic_uuid="$(new_uuid)"
  tuic_password="$(random_urlsafe 24)"
  ss_password="$(random_base64 16)"
  anytls_password="$(random_urlsafe 24)"
  vision_uuid="$(new_uuid)"
  xhttp_uuid="$(new_uuid)"
  vision_pair="$(generate_reality_pair)"
  xhttp_pair="$(generate_reality_pair)"
  read -r vision_private vision_public <<< "$vision_pair"
  read -r xhttp_private xhttp_public <<< "$xhttp_pair"
  vision_sid="$(random_hex 8)"
  xhttp_sid="$(random_hex 8)"
  xhttp_path="/$(random_urlsafe 12)"
  sub_token="$(random_urlsafe 24)"
  installed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  listen_address="::"

  jq -n \
    --arg release "$NEKO_RELEASE" \
    --arg installed_at "$installed_at" \
    --arg os_id "$OS_ID" --arg os_version "$OS_VERSION" --arg arch "$ARCH" \
    --arg xray_version "$XRAY_VERSION" --arg sing_version "$SING_BOX_VERSION" \
    --arg hysteria_version "$HYSTERIA_VERSION" --arg caddy_version "$CADDY_VERSION" \
    --arg lego_version "$LEGO_VERSION" \
    --arg domain "$DOMAIN" --arg email "$ACME_EMAIL" --arg listen "$listen_address" \
    --arg acme_method "$ACME_METHOD" \
    --argjson hy2_start "$HY2_START" --argjson hy2_end "$HY2_END" \
    --argjson tuic_port "$TUIC_PORT" --argjson ss_port "$SS_PORT" \
    --argjson anytls_port "$ANYTLS_PORT" --argjson vision_port "$VISION_PORT" \
    --argjson xhttp_port "$XHTTP_PORT" \
    --arg hy2_password "$hy2_password" --arg hy2_obfs "$hy2_obfs_password" \
    --arg tuic_uuid "$tuic_uuid" --arg tuic_password "$tuic_password" \
    --arg ss_password "$ss_password" --arg anytls_password "$anytls_password" \
    --arg vision_uuid "$vision_uuid" --arg xhttp_uuid "$xhttp_uuid" \
    --arg vision_private "$vision_private" --arg vision_public "$vision_public" \
    --arg vision_sid "$vision_sid" --arg xhttp_private "$xhttp_private" \
    --arg xhttp_public "$xhttp_public" --arg xhttp_sid "$xhttp_sid" \
    --arg xhttp_path "$xhttp_path" --arg sub_token "$sub_token" \
    --arg subscription_domain_ipv4 "$SUBSCRIPTION_DOMAIN_IPV4" \
    --arg subscription_domain_ipv6 "$SUBSCRIPTION_DOMAIN_IPV6" \
    --arg subscription_address_ipv4 "$SUBSCRIPTION_IPV4_ADDRESS" \
    --arg subscription_address_ipv6 "$SUBSCRIPTION_IPV6_ADDRESS" \
    '{
      schema: 2,
      release: $release,
      installed_at: $installed_at,
      platform: {id: $os_id, version: $os_version, arch: $arch},
      versions: {
        xray: $xray_version,
        sing_box: $sing_version,
        hysteria: $hysteria_version,
        caddy: $caddy_version,
        lego: $lego_version
      },
      domain: $domain,
      acme_email: $email,
      acme: {method: $acme_method},
      network: {listen_address: $listen},
      system_user_created: true,
      ports: {
        hysteria2_start: $hy2_start,
        hysteria2_end: $hy2_end,
        tuic: $tuic_port,
        ss2022: $ss_port,
        anytls: $anytls_port,
        vless_reality_vision: $vision_port,
        vless_reality_xhttp: $xhttp_port
      },
      credentials: {
        hysteria2_password: $hy2_password,
        hysteria2_obfs_password: $hy2_obfs,
        tuic_uuid: $tuic_uuid,
        tuic_password: $tuic_password,
        ss2022_password: $ss_password,
        anytls_password: $anytls_password,
        vision_uuid: $vision_uuid,
        xhttp_uuid: $xhttp_uuid
      },
      reality: {
        vision_private_key: $vision_private,
        vision_public_key: $vision_public,
        vision_short_id: $vision_sid,
        xhttp_private_key: $xhttp_private,
        xhttp_public_key: $xhttp_public,
        xhttp_short_id: $xhttp_sid,
        xhttp_path: $xhttp_path
      },
      subscription: {
        token: $sub_token,
        ipv4_domain: $subscription_domain_ipv4,
        ipv6_domain: $subscription_domain_ipv6,
        ipv4_address: $subscription_address_ipv4,
        ipv6_address: $subscription_address_ipv6
      },
      firewall: {manager: "none", zone: "", zones: []},
      bbr: {managed: false, previous_qdisc: "", previous_congestion_control: ""}
    }' > "$NEKO_STATE"
  chmod 0600 "$NEKO_STATE"
  chown root:root "$NEKO_STATE"
}

validate_generated_configs() {
  info "用冻结的核心二进制校验生成配置……"
  "$NEKO_LIBEXEC/sing-box" check -c "$NEKO_ETC/config/sing-box.json"
  "$NEKO_LIBEXEC/xray" run -test -c "$NEKO_ETC/config/xray.json"
  "$NEKO_LIBEXEC/caddy" validate --config "$NEKO_ETC/config/Caddyfile" --adapter caddyfile
  ok "sing-box、Xray 与 Caddy 配置校验通过。"
}

start_services() {
  local service
  systemctl daemon-reload
  systemctl enable \
    neko-caddy.service neko-sing-box.service neko-xray.service \
    neko-hysteria.service neko-renew.timer >/dev/null

  for service in neko-caddy neko-sing-box neko-hysteria neko-xray; do
    if ! systemctl start "${service}.service"; then
      journalctl -u "${service}.service" -n 60 --no-pager >&2 || true
      die "${service} 启动失败。"
    fi
    systemctl is-active --quiet "${service}.service" || die "${service} 未保持运行。"
  done
  # Type=simple returns as soon as the supervisor starts. Give both Hysteria
  # children and the other cores a short grace period to expose bind/runtime
  # failures before declaring the transaction successful.
  sleep 2
  for service in neko-caddy neko-sing-box neko-hysteria neko-xray; do
    if ! systemctl is-active --quiet "${service}.service"; then
      journalctl -u "${service}.service" -n 60 --no-pager >&2 || true
      die "${service} 未通过启动稳定性检查。"
    fi
  done
  systemctl start neko-renew.timer
  systemctl is-active --quiet neko-renew.timer || die "证书续期定时器未运行。"
}

main() {
  parse_args "$@"
  require_root
  detect_platform
  require_systemd

  require_commands getent awk sort grep
  collect_identity
  # Keep the domain gate ahead of package installation and all Neko file
  # creation.  Recheck the target after taking the lock to close the race
  # between two installers that passed the initial read-only check.
  assert_clean_target
  install_dependencies
  require_commands curl jq openssl tar unzip ss getent flock sha256sum systemctl find nft useradd df awk stat env ip tee

  exec 9>/run/lock/neko-install.lock
  flock -n 9 || die "另一个 Neko 安装进程正在运行。"
  assert_clean_target
  assert_dual_stack_kernel
  assert_strict_addresses_local
  assert_public_ports_free
  assert_work_space

  WORKDIR="$(mktemp -d "${NEKO_WORK_BASE}/neko-install.XXXXXX")"
  download_release_binaries
  issue_initial_certificate
  create_service_user_and_dirs
  install_payload
  write_initial_state
  render_all
  validate_generated_configs
  configure_firewall
  start_services

  ROLLBACK_NEEDED=0
  ok "Neko ${NEKO_RELEASE} 安装完成。"
  show_subscription_links
  show_required_ports
  warn "请按上面的精确列表配置云厂商安全组；本机防火墙规则不能代替云安全组。"
  printf '以后输入 neko 打开终端控制面板。\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
