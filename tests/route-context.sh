#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-route-context.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/etc"
cp -- "$ROOT/tests/fixtures/state.json" "$WORK/etc/state.json"

NEKO_ETC="$WORK/etc" NEKO_VAR="$WORK/var" \
  NEKO_STATE="$WORK/etc/state.json" bash -c '
    set -Eeuo pipefail
    source "$1"
    source "$2"
    load_state

    assert_invalid_context() {
      local expected="$1" output rc
      set +e
      output="$(route_context_validate route 2>&1)"
      rc=$?
      set -e
      (( rc == 64 ))
      [[ "$output" == *"$expected"* ]]
    }

    declare -A route=(
      [profile]=v4
      [server]="$SUBSCRIPTION_IPV4_ADDRESS"
      [ingress_family]=ipv4
      [egress_family]=ipv4
      [dns_mode]=public
      [dns_server]=1.1.1.1
      [dns_strategy]=ipv4_only
      [rejected_ip_family]=ipv6
    )
    route_context_set_ports route normal
    route_context_validate route
    [[ "${route[port_set]}" == normal ]]
    [[ "${route[hy2_start]}" == "$HY2_START" ]]
    [[ "${route[xhttp_port]}" == "$XHTTP_PORT" ]]
    [[ "${route[anyreality_enabled]}" == "$ANYREALITY_ENABLED" ]]
    [[ "${route[anyreality_port]}" == "$ANYREALITY_PORT" ]]

    unset "route[xhttp_port]"
    assert_invalid_context "缺少字段 xhttp_port"
    route[xhttp_port]="$XHTTP_PORT"
    route[unexpected]=value
    assert_invalid_context "未知字段 unexpected"
    unset "route[unexpected]"
    route[egress_family]=ipv6
    assert_invalid_context "出站地址族不一致"
    route[egress_family]=ipv4
    route[hy2_end]="$((HY2_START - 1))"
    assert_invalid_context "Hysteria2 端口范围倒置"
    route[hy2_end]="$HY2_END"

    route=(
      [profile]=v4-to-v6
      [server]="$SUBSCRIPTION_IPV4_ADDRESS"
      [ingress_family]=ipv4
      [egress_family]=ipv6
      [dns_mode]=public
      [dns_server]="2606:4700:4700::1111"
      [dns_strategy]=ipv6_only
      [rejected_ip_family]=ipv4
    )
    route_context_set_ports route cross
    route_context_validate route
    [[ "${route[port_set]}" == cross ]]
    [[ "${route[hy2_start]}" == "$CROSS_HY2_START" ]]
    [[ "${route[xhttp_port]}" == "$CROSS_XHTTP_PORT" ]]

    route[anyreality_enabled]=false
    route[anyreality_port]=""
    render_client_yaml() { :; }
    render_stash_yaml() { :; }
    render_shadowrocket() {
      [[ "${11}" == "" && "${12}" == false ]]
    }
    render_sing_box_client() {
      [[ "${14}" == "" && "${15}" == false ]]
    }
    render_subscription_route route

    set +e
    arity_output="$(render_subscription_route route extra 2>&1)"
    arity_rc=$?
    set -e
    (( arity_rc == 64 ))
    [[ "$arity_output" == *"只接受一个具名上下文"* ]]
  ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"

printf '具名线路上下文、方向约束、端口集和可选协议契约测试通过。\n'
