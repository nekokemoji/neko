#!/usr/bin/env bash

set -Eeuo pipefail

root="${NEKO_AKDNS_SYSTEM_ROOT%/}"
resolv="${root}/etc/resolv.conf"
nsswitch="${root}/etc/nsswitch.conf"
nm_conf="${root}/etc/NetworkManager/conf.d/akdns-dns.conf"
action="${NEKO_AKDNS_TEST_ACTION:-nochange}"

apply_akdns() {
  mkdir -p -- "$(dirname -- "$nm_conf")"
  rm -f -- "$resolv"
  printf 'nameserver 66.66.66.66\noptions use-vc\n' > "$resolv"
  cp -a -- "$nsswitch" "${nsswitch}.akdns.bak"
  printf 'hosts: files dns\n' > "$nsswitch"
  printf '[main]\ndns=none\n' > "$nm_conf"
  "$NEKO_AKDNS_SYSTEMCTL" disable systemd-resolved.service >/dev/null
  "$NEKO_AKDNS_SYSTEMCTL" stop systemd-resolved.service >/dev/null
}

case "$action" in
  apply)
    apply_akdns
    ;;
  fail)
    apply_akdns
    exit 42
    ;;
  interrupt)
    apply_akdns
    kill -TERM "$PPID"
    sleep 1
    ;;
  invalid)
    mkdir -p -- "$(dirname -- "$nm_conf")"
    rm -f -- "$resolv"
    printf 'nameserver 192.0.2.53\n' > "$resolv"
    printf '[main]\ndns=none\n' > "$nm_conf"
    ;;
  restore)
    rm -f -- "$resolv" "$nm_conf"
    printf 'nameserver 192.0.2.1\n' > "$resolv"
    "$NEKO_AKDNS_SYSTEMCTL" enable systemd-resolved.service >/dev/null
    "$NEKO_AKDNS_SYSTEMCTL" start systemd-resolved.service >/dev/null
    ;;
  nochange)
    ;;
  *)
    printf '未知 AKDNS 测试动作：%s\n' "$action" >&2
    exit 2
    ;;
esac
