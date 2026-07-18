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
  command -v ufw >/dev/null 2>&1 || return 1
  if [[ -r /etc/ufw/ufw.conf ]]; then
    grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes[[:space:]]*$' /etc/ufw/ufw.conf
  else
    ufw status 2>/dev/null | grep -qi '^Status: active'
  fi
}

set_firewall_manager() {
  local manager="$1" zone="${2:-}"
  atomic_json_update \
    '.firewall.manager = $manager | .firewall.zone = $zone' \
    --arg manager "$manager" --arg zone "$zone"
}

configure_firewalld() {
  local zone
  zone="$(firewall-cmd --get-default-zone)"
  [[ -n "$zone" ]] || die "无法确定 firewalld 默认区域。"
  [[ ! -e "$FIREWALLD_SERVICE_FILE" ]] || die "防火墙服务文件已存在：${FIREWALLD_SERVICE_FILE}"
  set_firewall_manager firewalld "$zone"
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
  firewall-cmd --permanent --zone="$zone" --add-service=neko-proxy >/dev/null
  firewall-cmd --reload >/dev/null
  ok "已添加 firewalld 的 Neko Proxy 专用服务规则。"
}

configure_ufw() {
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
  if [[ -r "$NEKO_STATE" ]]; then
    manager="$(jq -r '.firewall.manager // "none"' "$NEKO_STATE" 2>/dev/null || printf 'none')"
    zone="$(jq -r '.firewall.zone // empty' "$NEKO_STATE" 2>/dev/null || true)"
  fi

  case "$manager" in
    firewalld)
      if command -v firewall-cmd >/dev/null 2>&1; then
        if [[ -n "$zone" ]]; then
          firewall-cmd --permanent --zone="$zone" --remove-service=neko-proxy >/dev/null 2>&1 || true
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
