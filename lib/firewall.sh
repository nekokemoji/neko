#!/usr/bin/env bash

# Manage only a named Neko firewall profile.  Existing user rules are untouched.

set -Eeuo pipefail

if ! declare -F load_state >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

FIREWALLD_SERVICE_FILE="${FIREWALLD_SERVICE_FILE:-/etc/firewalld/services/neko-proxy.xml}"
UFW_PROFILE_FILE="${UFW_PROFILE_FILE:-/etc/ufw/applications.d/neko-proxy}"

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
    ip -4 route show default 2>/dev/null || true
    ip -6 route show default 2>/dev/null || true
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

configure_firewalld() {
  local zone
  local -a zones=()
  mapfile -t zones < <(firewalld_target_zones)
  (( ${#zones[@]} > 0 )) || die "无法确定公网默认路由使用的 firewalld 区域。"
  [[ ! -e "$FIREWALLD_SERVICE_FILE" ]] || die "防火墙服务文件已存在：${FIREWALLD_SERVICE_FILE}"
  set_firewall_manager firewalld "${zones[@]}"
  mkdir -p "$(dirname -- "$FIREWALLD_SERVICE_FILE")"
  local tmp
  tmp="$(mktemp "${FIREWALLD_SERVICE_FILE}.tmp.XXXXXX")"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Neko Proxy</short>
  <description>Neko managed proxy listeners and HTTPS subscriptions</description>
  <port protocol="tcp" port="80"/>
  <port protocol="tcp" port="443"/>
  <port protocol="tcp" port="${SS_PORT}"/>
  <port protocol="udp" port="${SS_PORT}"/>
  <port protocol="tcp" port="${ANYTLS_PORT}"/>
  <port protocol="tcp" port="${VISION_PORT}"/>
  <port protocol="tcp" port="${XHTTP_PORT}"/>
  <port protocol="udp" port="${TUIC_PORT}"/>
  <port protocol="udp" port="${HY2_START}-${HY2_END}"/>
</service>
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$FIREWALLD_SERVICE_FILE"

  firewall-cmd --reload >/dev/null
  for zone in "${zones[@]}"; do
    firewall-cmd --permanent --zone="$zone" --add-service=neko-proxy >/dev/null
  done
  firewall-cmd --reload >/dev/null
  for zone in "${zones[@]}"; do
    firewall-cmd --zone="$zone" --query-service=neko-proxy >/dev/null \
      || die "firewalld 区域 ${zone} 的 Neko 规则未生效。"
  done
  ok "已在默认 IPv4/IPv6 路由对应的 firewalld 区域添加 Neko Proxy 专用规则：${zones[*]}。"
}

configure_ufw() {
  local ufw_status
  if [[ -r /etc/default/ufw ]] \
    && grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no[[:space:]]*$' /etc/default/ufw; then
    die "UFW 已禁用 IPv6 规则管理；严格 IPv6 服务无法安全放行。请先设置 IPV6=yes 并重载 UFW。"
  fi
  [[ ! -e "$UFW_PROFILE_FILE" ]] || die "UFW 应用配置已存在：${UFW_PROFILE_FILE}"
  set_firewall_manager ufw
  mkdir -p "$(dirname -- "$UFW_PROFILE_FILE")"
  local tmp
  tmp="$(mktemp "${UFW_PROFILE_FILE}.tmp.XXXXXX")"
  cat > "$tmp" <<EOF
[NekoProxy]
title=Neko Proxy
description=Neko managed proxy listeners and HTTPS subscriptions
ports=80,443,${SS_PORT},${ANYTLS_PORT},${VISION_PORT},${XHTTP_PORT}/tcp|${SS_PORT},${TUIC_PORT},${HY2_START}:${HY2_END}/udp
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$UFW_PROFILE_FILE"

  ufw app update NekoProxy >/dev/null
  ufw allow NekoProxy >/dev/null
  ufw_status="$(ufw status 2>/dev/null || true)"
  grep -Fq NekoProxy <<< "$ufw_status" || die "UFW 的 NekoProxy 规则未生效。"
  ok "已添加 UFW 的 NekoProxy 专用应用规则。"
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
