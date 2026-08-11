#!/usr/bin/env bash

# Manage only a named Neko firewall profile.  Existing user rules are untouched.

set -Eeuo pipefail

if ! declare -F load_state >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

FIREWALLD_SERVICE_FILE="${FIREWALLD_SERVICE_FILE:-/etc/firewalld/services/neko-proxy.xml}"
UFW_PROFILE_FILE="${UFW_PROFILE_FILE:-/etc/ufw/applications.d/neko-proxy}"
TEMP_HTTP_UFW_PROFILE_FILE="${TEMP_HTTP_UFW_PROFILE_FILE:-/etc/ufw/applications.d/neko-acme-temporary}"
TEMP_HTTP_FIREWALL_MANAGER="none"
TEMP_HTTP_UFW_PROFILE_CREATED=0
declare -a TEMP_HTTP_FIREWALL_ZONES=()

firewalld_is_active() {
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

ufw_is_active() {
  local status
  command -v ufw >/dev/null 2>&1 || return 1
  if [[ -r /etc/ufw/ufw.conf ]]; then
    grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes[[:space:]]*$' /etc/ufw/ufw.conf
  else
    status="$(ufw status 2>/dev/null || true)"
    grep -qi '^Status: active' <<< "$status"
  fi
}

set_firewall_manager() {
  local manager="$1" primary_zone="" zones_json
  shift
  if (( $# > 0 )); then
    primary_zone="$1"
    zones_json="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  else
    zones_json='[]'
  fi
  atomic_json_update \
    '.firewall.manager = $manager
     | .firewall.zone = $zone
     | .firewall.zones = $zones' \
    --arg manager "$manager" --arg zone "$primary_zone" --argjson zones "$zones_json"
}

firewalld_target_zones() {
  local interfaces interface zone default_zone
  default_zone="$(firewall-cmd --get-default-zone)"
  [[ -n "$default_zone" ]] || die "无法确定 firewalld 默认区域。"

  interfaces="$({
    if network_mode_has_ipv4; then
      ip -4 route show default 2>/dev/null || true
    fi
    if network_mode_has_ipv6; then
      ip -6 route show default 2>/dev/null || true
    fi
  } | awk '{for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) print $(i + 1)}' \
    | sort -u)"

  if [[ -z "$interfaces" ]]; then
    printf '%s\n' "$default_zone"
    return 0
  fi

  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    zone="$(firewall-cmd "--get-zone-of-interface=${interface}" 2>/dev/null || true)"
    if [[ -z "$zone" || "$zone" == "no zone" ]]; then
      zone="$default_zone"
    fi
    printf '%s\n' "$zone"
  done <<< "$interfaces" | sort -u
}

open_temporary_http_challenge_port() {
  local zone tmp ufw_status
  local -a zones=()

  TEMP_HTTP_FIREWALL_MANAGER="none"
  TEMP_HTTP_UFW_PROFILE_CREATED=0
  TEMP_HTTP_FIREWALL_ZONES=()

  if firewalld_is_active; then
    mapfile -t zones < <(firewalld_target_zones)
    (( ${#zones[@]} > 0 )) || die "无法确定 HTTP-01 应放行的 firewalld 区域。"
    TEMP_HTTP_FIREWALL_MANAGER="firewalld"
    for zone in "${zones[@]}"; do
      if firewall-cmd --zone="$zone" --query-port=80/tcp >/dev/null 2>&1; then
        continue
      fi
      firewall-cmd --zone="$zone" --add-port=80/tcp --timeout=10m >/dev/null \
        || die "无法在 firewalld 区域 ${zone} 临时放行 TCP 80。"
      TEMP_HTTP_FIREWALL_ZONES+=("$zone")
      firewall-cmd --zone="$zone" --query-port=80/tcp >/dev/null \
        || die "firewalld 区域 ${zone} 的临时 TCP 80 规则未生效。"
    done
    ok "HTTP-01 验证期间已临时放行 TCP 80；规则最长保留 10 分钟。"
    return 0
  fi

  if ufw_is_active; then
    if network_mode_has_ipv6 \
      && [[ -r /etc/default/ufw ]] \
      && grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no[[:space:]]*$' /etc/default/ufw; then
      die "UFW 已禁用 IPv6 规则管理；HTTP-01 无法安全放行严格 IPv6 域名。请先设置 IPV6=yes 并重载 UFW。"
    fi
    [[ ! -e "$TEMP_HTTP_UFW_PROFILE_FILE" ]] \
      || die "临时 HTTP-01 防火墙配置已存在：${TEMP_HTTP_UFW_PROFILE_FILE}"
    TEMP_HTTP_FIREWALL_MANAGER="ufw"
    mkdir -p "$(dirname -- "$TEMP_HTTP_UFW_PROFILE_FILE")"
    tmp="$(mktemp "${TEMP_HTTP_UFW_PROFILE_FILE}.tmp.XXXXXX")"
    cat > "$tmp" <<'EOF'
[NekoACMETemporary]
title=Neko temporary ACME HTTP-01
description=Temporary TCP 80 access used only while obtaining the initial certificate
ports=80/tcp
EOF
    chmod 0644 "$tmp"
    mv -f "$tmp" "$TEMP_HTTP_UFW_PROFILE_FILE"
    TEMP_HTTP_UFW_PROFILE_CREATED=1
    ufw app update NekoACMETemporary >/dev/null
    ufw allow NekoACMETemporary >/dev/null
    ufw_status="$(ufw status 2>/dev/null || true)"
    grep -Fq NekoACMETemporary <<< "$ufw_status" \
      || die "UFW 的临时 TCP 80 规则未生效。"
    ok "HTTP-01 验证期间已在 UFW 临时放行 TCP 80。"
    return 0
  fi

  warn "未发现正在启用的 firewalld 或 UFW；HTTP-01 将直接尝试 TCP 80。云安全组或自定义 nftables/iptables 仍可能拦截。"
}

close_temporary_http_challenge_port() {
  local zone cleanup_failed=0

  case "$TEMP_HTTP_FIREWALL_MANAGER" in
    firewalld)
      if command -v firewall-cmd >/dev/null 2>&1; then
        for zone in "${TEMP_HTTP_FIREWALL_ZONES[@]}"; do
          firewall-cmd --zone="$zone" --remove-port=80/tcp >/dev/null 2>&1 \
            || cleanup_failed=1
        done
      elif (( ${#TEMP_HTTP_FIREWALL_ZONES[@]} > 0 )); then
        cleanup_failed=1
      fi
      ;;
    ufw)
      if (( TEMP_HTTP_UFW_PROFILE_CREATED == 1 )); then
        if command -v ufw >/dev/null 2>&1; then
          ufw --force delete allow NekoACMETemporary >/dev/null 2>&1 \
            || cleanup_failed=1
        else
          cleanup_failed=1
        fi
        rm -f -- "$TEMP_HTTP_UFW_PROFILE_FILE" || cleanup_failed=1
      fi
      ;;
    none)
      ;;
    *)
      cleanup_failed=1
      ;;
  esac

  TEMP_HTTP_FIREWALL_MANAGER="none"
  TEMP_HTTP_UFW_PROFILE_CREATED=0
  TEMP_HTTP_FIREWALL_ZONES=()
  if (( cleanup_failed == 1 )); then
    warn "临时 TCP 80 规则未能完全清理；请检查本机防火墙。firewalld 临时规则会在 10 分钟内自动过期。"
  fi
  return 0
}

write_firewalld_service_file() {
  local tmp
  mkdir -p "$(dirname -- "$FIREWALLD_SERVICE_FILE")"
  tmp="$(mktemp "${FIREWALLD_SERVICE_FILE}.tmp.XXXXXX")"
  {
    cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Neko Proxy</short>
  <description>Neko managed proxy listeners and HTTPS subscriptions</description>
  <port protocol="tcp" port="80"/>
  <port protocol="tcp" port="443"/>
  <port protocol="tcp" port="${SS_PORT}"/>
  <port protocol="udp" port="${SS_PORT}"/>
  <port protocol="tcp" port="${ANYTLS_PORT}"/>
  <port protocol="tcp" port="${TROJAN_PORT}"/>
  <port protocol="tcp" port="${VISION_PORT}"/>
  <port protocol="tcp" port="${XHTTP_PORT}"/>
  <port protocol="udp" port="${TUIC_PORT}"/>
  <port protocol="udp" port="${HY2_START}-${HY2_END}"/>
EOF
    if [[ "$ANYREALITY_ENABLED" == "true" ]]; then
      printf '  <port protocol="tcp" port="%s"/>\n' "$ANYREALITY_PORT"
    fi
    if network_mode_has_cross_routes; then
      cat <<EOF
  <port protocol="tcp" port="${CROSS_SS_PORT}"/>
  <port protocol="udp" port="${CROSS_SS_PORT}"/>
  <port protocol="tcp" port="${CROSS_ANYTLS_PORT}"/>
  <port protocol="tcp" port="${CROSS_TROJAN_PORT}"/>
  <port protocol="tcp" port="${CROSS_VISION_PORT}"/>
  <port protocol="tcp" port="${CROSS_XHTTP_PORT}"/>
  <port protocol="udp" port="${CROSS_TUIC_PORT}"/>
  <port protocol="udp" port="${CROSS_HY2_START}-${CROSS_HY2_END}"/>
EOF
      if [[ "$ANYREALITY_ENABLED" == "true" ]]; then
        printf '  <port protocol="tcp" port="%s"/>\n' "$CROSS_ANYREALITY_PORT"
      fi
    fi
    cat <<'EOF'
</service>
EOF
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$FIREWALLD_SERVICE_FILE"
}

write_ufw_profile_file() {
  local tmp tcp_ports udp_ports
  mkdir -p "$(dirname -- "$UFW_PROFILE_FILE")"
  tmp="$(mktemp "${UFW_PROFILE_FILE}.tmp.XXXXXX")"
  tcp_ports="80,443,${SS_PORT},${ANYTLS_PORT},${TROJAN_PORT},${VISION_PORT},${XHTTP_PORT}"
  udp_ports="${SS_PORT},${TUIC_PORT},${HY2_START}:${HY2_END}"
  if network_mode_has_cross_routes; then
    tcp_ports+=",${CROSS_SS_PORT},${CROSS_ANYTLS_PORT},${CROSS_TROJAN_PORT},${CROSS_VISION_PORT},${CROSS_XHTTP_PORT}"
    udp_ports+=",${CROSS_SS_PORT},${CROSS_TUIC_PORT},${CROSS_HY2_START}:${CROSS_HY2_END}"
  fi
  if [[ "$ANYREALITY_ENABLED" == "true" ]]; then
    tcp_ports+=",${ANYREALITY_PORT}"
    if network_mode_has_cross_routes; then
      tcp_ports+=",${CROSS_ANYREALITY_PORT}"
    fi
  fi
  cat > "$tmp" <<EOF
[NekoProxy]
title=Neko Proxy
description=Neko managed proxy listeners and HTTPS subscriptions
ports=${tcp_ports}/tcp|${udp_ports}/udp
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$UFW_PROFILE_FILE"
}

configure_firewalld() {
  local zone
  local -a zones=()
  mapfile -t zones < <(firewalld_target_zones)
  (( ${#zones[@]} > 0 )) || die "无法确定公网默认路由使用的 firewalld 区域。"
  [[ ! -e "$FIREWALLD_SERVICE_FILE" ]] || die "防火墙服务文件已存在：${FIREWALLD_SERVICE_FILE}"
  set_firewall_manager firewalld "${zones[@]}"
  write_firewalld_service_file

  firewall-cmd --reload >/dev/null
  for zone in "${zones[@]}"; do
    firewall-cmd --permanent --zone="$zone" --add-service=neko-proxy >/dev/null
  done
  firewall-cmd --reload >/dev/null
  for zone in "${zones[@]}"; do
    firewall-cmd --zone="$zone" --query-service=neko-proxy >/dev/null \
      || die "firewalld 区域 ${zone} 的 Neko 规则未生效。"
  done
  ok "已在 $(network_mode_label) 默认路由对应的 firewalld 区域添加 Neko Proxy 专用规则：${zones[*]}。"
}

configure_ufw() {
  local ufw_status
  if network_mode_has_ipv6 \
    && [[ -r /etc/default/ufw ]] \
    && grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no[[:space:]]*$' /etc/default/ufw; then
    die "UFW 已禁用 IPv6 规则管理；严格 IPv6 服务无法安全放行。请先设置 IPV6=yes 并重载 UFW。"
  fi
  [[ ! -e "$UFW_PROFILE_FILE" ]] || die "UFW 应用配置已存在：${UFW_PROFILE_FILE}"
  set_firewall_manager ufw
  write_ufw_profile_file

  ufw app update NekoProxy >/dev/null
  ufw allow NekoProxy >/dev/null
  ufw_status="$(ufw status 2>/dev/null || true)"
  grep -Fq NekoProxy <<< "$ufw_status" || die "UFW 的 NekoProxy 规则未生效。"
  ok "已添加 UFW 的 NekoProxy 专用应用规则。"
}

sync_managed_firewall_profile() {
  local manager zone old_zone ufw_status
  local -a zones=()

  load_state
  manager="$(jq -r '.firewall.manager // "none"' "$NEKO_STATE")"
  case "$manager" in
    firewalld)
      firewalld_is_active \
        || die "原安装由 firewalld 管理，但 firewalld 当前未运行。"
      [[ -f "$FIREWALLD_SERVICE_FILE" && ! -L "$FIREWALLD_SERVICE_FILE" ]] \
        || die "Neko 的 firewalld 服务文件缺失或类型异常。"
      mapfile -t zones < <(jq -r '.firewall.zones[]? // empty' "$NEKO_STATE")
      if (( ${#zones[@]} == 0 )); then
        old_zone="$(jq -r '.firewall.zone // empty' "$NEKO_STATE")"
        [[ -z "$old_zone" ]] || zones=("$old_zone")
      fi
      (( ${#zones[@]} > 0 )) || die "state.json 未记录 Neko 使用的 firewalld 区域。"
      write_firewalld_service_file
      firewall-cmd --reload >/dev/null || die "firewalld 重载失败。"
      for zone in "${zones[@]}"; do
        firewall-cmd --zone="$zone" --query-service=neko-proxy >/dev/null \
          || die "firewalld 区域 ${zone} 的 Neko 规则未生效。"
      done
      ;;
    ufw)
      ufw_is_active || die "原安装由 UFW 管理，但 UFW 当前未运行。"
      [[ -f "$UFW_PROFILE_FILE" && ! -L "$UFW_PROFILE_FILE" ]] \
        || die "Neko 的 UFW 应用配置缺失或类型异常。"
      write_ufw_profile_file
      ufw app update NekoProxy >/dev/null || die "UFW 应用规则更新失败。"
      ufw_status="$(ufw status 2>/dev/null || true)"
      grep -Fq NekoProxy <<< "$ufw_status" || die "UFW 的 NekoProxy 规则未生效。"
      ;;
    none)
      ;;
    *)
      die "state.json 记录了未知防火墙管理器：${manager}"
      ;;
  esac
}

configure_firewall() {
  load_state
  if firewalld_is_active; then
    configure_firewalld
  elif ufw_is_active; then
    configure_ufw
  else
    set_firewall_manager none
    warn "未发现正在启用的 firewalld 或 UFW；没有改动现有 nftables/iptables 规则。"
  fi
}

remove_firewall() {
  local manager="none" zone=""
  local -a zones=()
  if [[ -r "$NEKO_STATE" ]]; then
    manager="$(jq -r '.firewall.manager // "none"' "$NEKO_STATE" 2>/dev/null || printf 'none')"
    zone="$(jq -r '.firewall.zone // empty' "$NEKO_STATE" 2>/dev/null || true)"
    mapfile -t zones < <(jq -r '.firewall.zones[]? // empty' "$NEKO_STATE" 2>/dev/null || true)
    if (( ${#zones[@]} == 0 )) && [[ -n "$zone" ]]; then
      zones=("$zone")
    fi
  fi

  case "$manager" in
    firewalld)
      if command -v firewall-cmd >/dev/null 2>&1; then
        if (( ${#zones[@]} > 0 )); then
          for zone in "${zones[@]}"; do
            firewall-cmd --permanent --zone="$zone" --remove-service=neko-proxy \
              >/dev/null 2>&1 || true
          done
        else
          firewall-cmd --permanent --remove-service=neko-proxy >/dev/null 2>&1 || true
        fi
      fi
      rm -f -- "$FIREWALLD_SERVICE_FILE"
      if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --reload >/dev/null 2>&1 || true
      fi
      ;;
    ufw)
      if command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow NekoProxy >/dev/null 2>&1 || true
      fi
      rm -f -- "$UFW_PROFILE_FILE"
      ;;
    none)
      ;;
    *)
      warn "未知的防火墙记录：${manager}；未改动用户防火墙。"
      ;;
  esac
}
