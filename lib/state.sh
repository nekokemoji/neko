#!/usr/bin/env bash

# Central state I/O, validation, and migration contracts.
# This library is sourced by lib/common.sh so legacy callers keep the same API.

state_schema_value() {
  jq -er '
    (if .schema == null then 1 else .schema end)
    | select(type == "number" and . == floor)
  ' "$1"
}

state_validate_exact_schema() {
  local state_file="$1" schema="$2"
  validate_state_source_contract "$state_file" "$schema" "$schema"
}

state_atomic_commit_candidate() {
  local candidate="$1" target="$2" schema="$3" tmp=""
  state_validate_exact_schema "$candidate" "$schema" || return
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return
  if ! install -m 0600 -- "$candidate" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chown root:root "$tmp" 2>/dev/null || true
  if ! state_validate_exact_schema "$tmp" "$schema"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

state_migration_step() {
  local source="$1" target="$2" source_schema="$3" target_schema="$4"
  local filter="$5" tmp=""
  shift 5
  state_validate_exact_schema "$source" "$source_schema" || return
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return
  if ! jq "$@" "$filter" "$source" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  chown root:root "$tmp" 2>/dev/null || true
  if ! state_validate_exact_schema "$tmp" "$target_schema"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

state_atomic_json_update() {
  local state_file="$1" filter="$2"
  shift 2
  state_migration_step \
    "$state_file" "$state_file" "$NEKO_STATE_SCHEMA" "$NEKO_STATE_SCHEMA" \
    "$filter" "$@"
}

# Compatibility façade for all existing runtime callers.
atomic_json_update() {
  local filter="$1"
  shift
  state_atomic_json_update "$NEKO_STATE" "$filter" "$@"
}

state_value() {
  jq -er "$1" "$NEKO_STATE"
}

# This is a read-only source contract, not a migration layer.  It accepts the
# historical schemas the upgrader already supports, but never rewrites,
# normalizes, or fills a damaged value before the caller explicitly commits.
state_contract_fail() {
  printf 'state.json 验证失败：%s\n' "$*" >&2
  return 1
}

validate_canonical_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

validate_urlsafe_secret() {
  local value="$1" minimum="${2:-16}" maximum="${3:-128}"
  [[ "$minimum" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ ]] || return 1
  (( minimum <= maximum )) || return 1
  (( ${#value} >= minimum && ${#value} <= maximum )) || return 1
  [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

validate_reality_key() {
  validate_urlsafe_secret "$1" 43 43
}

validate_reality_short_id() {
  [[ "$1" =~ ^[0-9a-f]{16}$ ]]
}

validate_ss2022_password() {
  # AES-128-GCM uses exactly 16 bytes.  Their canonical Base64 form has 21
  # unrestricted symbols, one symbol whose low two bits are zero, and "==".
  [[ "$1" =~ ^[A-Za-z0-9+/]{21}[AEIMQUYcgkosw048]==$ ]]
}

validate_xhttp_path() {
  local path="$1" segment
  (( ${#path} >= 2 && ${#path} <= 256 )) || return 1
  [[ "$path" =~ ^/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || return 1
  IFS='/' read -r -a _xhttp_path_segments <<< "${path#/}"
  for segment in "${_xhttp_path_segments[@]}"; do
    [[ "$segment" != "." && "$segment" != ".." ]] || return 1
  done
}

validate_state_json_types() {
  local state_file="$1" minimum_schema="$2" maximum_schema="$3"
  [[ -r "$state_file" ]] || state_contract_fail "文件不可读。" || return
  [[ "$minimum_schema" =~ ^[0-9]+$ && "$maximum_schema" =~ ^[0-9]+$ ]] \
    || state_contract_fail "内部 schema 范围无效。" || return

  jq -e --argjson minimum_schema "$minimum_schema" \
    --argjson maximum_schema "$maximum_schema" '
      def integer: type == "number" and . == floor;
      def state_schema: if .schema == null then 1 else .schema end;
      def state_has_cross_routes:
        (.network.mode | ascii_downcase) as $mode
        | $mode == "both" or $mode == "dual" or $mode == "dual-stack";
      def optional_string: . == null or type == "string";
      def optional_integer: . == null or integer;
      def string_array: type == "array" and all(.[]; type == "string");
      def common_port_types:
        (.ports | type == "object")
        and (.ports.hysteria2_start | integer)
        and (.ports.hysteria2_end | integer)
        and (.ports.tuic | integer)
        and (.ports.ss2022 | integer)
        and (.ports.anytls | integer)
        and (.ports.trojan | optional_integer)
        and (.ports.vless_reality_vision | integer)
        and (.ports.vless_reality_xhttp | integer);
      def cross_port_types:
        type == "object"
        and (.hysteria2_start | integer)
        and (.hysteria2_end | integer)
        and (.tuic | integer)
        and (.ss2022 | integer)
        and (.anytls | integer)
        and (.trojan | integer)
        and (.vless_reality_vision | integer)
        and (.vless_reality_xhttp | integer);
      def common_credential_types:
        (.credentials | type == "object")
        and (.credentials.hysteria2_password | type == "string")
        and (.credentials.hysteria2_obfs_password | type == "string")
        and (.credentials.tuic_uuid | type == "string")
        and (.credentials.tuic_password | type == "string")
        and (.credentials.ss2022_password | type == "string")
        and (.credentials.anytls_password | type == "string")
        and (.credentials.trojan_password | optional_string)
        and (.credentials.vision_uuid | type == "string")
        and (.credentials.xhttp_uuid | type == "string");
      def reality_types:
        (.reality | type == "object")
        and (.reality.vision_private_key | type == "string")
        and (.reality.vision_public_key | type == "string")
        and (.reality.vision_short_id | type == "string")
        and (.reality.xhttp_private_key | type == "string")
        and (.reality.xhttp_public_key | type == "string")
        and (.reality.xhttp_short_id | type == "string")
        and (.reality.xhttp_path | type == "string");
      def subscription_types:
        (.subscription | type == "object")
        and (.subscription.token | optional_string)
        and (.subscription.shadowrocket_server | optional_string)
        and (.subscription.ipv4_token | optional_string)
        and (.subscription.ipv6_token | optional_string)
        and (.subscription.ipv4_to_ipv6_token | optional_string)
        and (.subscription.ipv6_to_ipv4_token | optional_string)
        and (.subscription.ipv4_domain | optional_string)
        and (.subscription.ipv6_domain | optional_string)
        and (.subscription.ipv4_address | optional_string)
        and (.subscription.ipv6_address | optional_string);
      def optional_metadata_types:
        (.release | optional_string)
        and (.installed_at | optional_string)
        and (.system_user_created == null or (.system_user_created | type == "boolean"))
        and (.platform == null or (
          (.platform | type == "object")
          and (.platform.id | optional_string)
          and (.platform.version | optional_string)
          and (.platform.arch | optional_string)))
        and (.versions == null or (
          (.versions | type == "object")
          and all(.versions[]; type == "string")))
        and (.firewall == null or (
          (.firewall | type == "object")
          and (.firewall.manager | optional_string)
          and (.firewall.zone | optional_string)
          and (.firewall.zones == null or (.firewall.zones | string_array))))
        and (.bbr == null or (
          (.bbr | type == "object")
          and (.bbr.managed == null or (.bbr.managed | type == "boolean"))
          and (.bbr.previous_qdisc | optional_string)
          and (.bbr.previous_congestion_control | optional_string)
          and (.bbr.previous_available_congestion_control | optional_string)
          and (.bbr.tcp_bbr_was_loaded == null
            or (.bbr.tcp_bbr_was_loaded | type == "boolean"))
          and (.bbr.sch_fq_was_loaded == null
            or (.bbr.sch_fq_was_loaded | type == "boolean"))));
      def optional_acme_type:
        .acme == null or (
          (.acme | type == "object") and (.acme.method | optional_string));
      def optional_anyreality_types:
        .experimental == null or (
          (.experimental | type == "object")
          and (.experimental.anyreality == null or (
            (.experimental.anyreality | type == "object")
            and (.experimental.anyreality.enabled == null
              or (.experimental.anyreality.enabled | type == "boolean"))
            and (.experimental.anyreality.port | optional_integer)
            and (.experimental.anyreality.cross_port | optional_integer)
            and (.experimental.anyreality.password | optional_string)
            and (.experimental.anyreality.private_key | optional_string)
            and (.experimental.anyreality.public_key | optional_string)
            and (.experimental.anyreality.short_id | optional_string))));

      type == "object"
      and (state_schema | integer)
      and (state_schema >= $minimum_schema)
      and (state_schema <= $maximum_schema)
      and ([.. | strings | select(test("[\\x{0000}-\\x{001F}\\x{007F}]"))]
        | length == 0)
      and ([.. | objects | keys[]
        | select(test("[\\x{0000}-\\x{001F}\\x{007F}]"))] | length == 0)
      and (.domain | type == "string")
      and (.acme_email | type == "string")
      and optional_acme_type
      and common_port_types
      and common_credential_types
      and reality_types
      and subscription_types
      and optional_metadata_types
      and optional_anyreality_types
      and (state_schema as $schema
        | if $schema >= 3 then
            (.network | type == "object")
            and (.network.mode | type == "string")
          elif $schema == 2 then
            (.network == null or (
              (.network | type == "object")
              and (.network.listen_address | optional_string)))
          else
            (.network == null or (.network | type == "object"))
          end)
      and (state_schema as $schema
        | if $schema <= 2 then
            (.subscription.token | type == "string")
          else true end)
      and (state_schema as $schema
        | if $schema == 4 and state_has_cross_routes then
            (.ports.cross | cross_port_types)
          elif $schema == 4 then
            .ports.cross == null
          else
            (.ports.cross == null or (.ports.cross | cross_port_types))
          end)
      and (if .experimental.anyreality.enabled == true then
          (.experimental.anyreality.port | integer)
          and (.experimental.anyreality.password | type == "string")
          and (.experimental.anyreality.private_key | type == "string")
          and (.experimental.anyreality.public_key | type == "string")
          and (.experimental.anyreality.short_id | type == "string")
          and (if state_schema == 4 and state_has_cross_routes then
              (.experimental.anyreality.cross_port | integer)
            else .experimental.anyreality.cross_port == null end)
        else true end)
    ' "$state_file" >/dev/null 2>&1 \
    || state_contract_fail "JSON、schema 或字段类型无效。"
}

validate_state_secret_contract() {
  local state_file="$1" secret_row
  local hy2_password hy2_obfs_password tuic_uuid tuic_password ss_password
  local anytls_password trojan_password vision_uuid xhttp_uuid
  local vision_private vision_public vision_short_id
  local xhttp_private xhttp_public xhttp_short_id xhttp_path
  local legacy_token ipv4_token ipv6_token ipv4_to_ipv6_token ipv6_to_ipv4_token
  local anyreality_enabled anyreality_password anyreality_private
  local anyreality_public anyreality_short_id token

  secret_row="$(jq -r '[
      .credentials.hysteria2_password,
      .credentials.hysteria2_obfs_password,
      .credentials.tuic_uuid,
      .credentials.tuic_password,
      .credentials.ss2022_password,
      .credentials.anytls_password,
      (.credentials.trojan_password // ""),
      .credentials.vision_uuid,
      .credentials.xhttp_uuid,
      .reality.vision_private_key,
      .reality.vision_public_key,
      .reality.vision_short_id,
      .reality.xhttp_private_key,
      .reality.xhttp_public_key,
      .reality.xhttp_short_id,
      .reality.xhttp_path,
      (.subscription.token // ""),
      (.subscription.ipv4_token // ""),
      (.subscription.ipv6_token // ""),
      (.subscription.ipv4_to_ipv6_token // ""),
      (.subscription.ipv6_to_ipv4_token // ""),
      ((.experimental.anyreality.enabled // false) | tostring),
      (.experimental.anyreality.password // ""),
      (.experimental.anyreality.private_key // ""),
      (.experimental.anyreality.public_key // ""),
      (.experimental.anyreality.short_id // "")
    ] | join("\u001f")' "$state_file")" \
    || state_contract_fail "无法读取凭据字段。" || return
  IFS=$'\x1f' read -r \
    hy2_password hy2_obfs_password tuic_uuid tuic_password ss_password \
    anytls_password trojan_password vision_uuid xhttp_uuid \
    vision_private vision_public vision_short_id \
    xhttp_private xhttp_public xhttp_short_id xhttp_path \
    legacy_token ipv4_token ipv6_token ipv4_to_ipv6_token ipv6_to_ipv4_token \
    anyreality_enabled anyreality_password anyreality_private \
    anyreality_public anyreality_short_id <<< "$secret_row"

  validate_urlsafe_secret "$hy2_password" \
    || state_contract_fail "Hysteria2 密码格式无效。" || return
  validate_urlsafe_secret "$hy2_obfs_password" \
    || state_contract_fail "Hysteria2 混淆密码格式无效。" || return
  validate_urlsafe_secret "$tuic_password" \
    || state_contract_fail "TUIC 密码格式无效。" || return
  validate_urlsafe_secret "$anytls_password" \
    || state_contract_fail "AnyTLS 密码格式无效。" || return
  if [[ -n "$trojan_password" ]]; then
    validate_urlsafe_secret "$trojan_password" \
      || state_contract_fail "Trojan 密码格式无效。" || return
  fi
  validate_canonical_uuid "$tuic_uuid" \
    || state_contract_fail "TUIC UUID 不是规范格式。" || return
  validate_canonical_uuid "$vision_uuid" \
    || state_contract_fail "Vision UUID 不是规范格式。" || return
  validate_canonical_uuid "$xhttp_uuid" \
    || state_contract_fail "XHTTP UUID 不是规范格式。" || return
  validate_ss2022_password "$ss_password" \
    || state_contract_fail "SS2022 密码不是规范的 16 字节 Base64。" || return
  validate_reality_key "$vision_private" \
    || state_contract_fail "Vision REALITY 私钥格式无效。" || return
  validate_reality_key "$vision_public" \
    || state_contract_fail "Vision REALITY 公钥格式无效。" || return
  validate_reality_key "$xhttp_private" \
    || state_contract_fail "XHTTP REALITY 私钥格式无效。" || return
  validate_reality_key "$xhttp_public" \
    || state_contract_fail "XHTTP REALITY 公钥格式无效。" || return
  validate_reality_short_id "$vision_short_id" \
    || state_contract_fail "Vision Short ID 格式无效。" || return
  validate_reality_short_id "$xhttp_short_id" \
    || state_contract_fail "XHTTP Short ID 格式无效。" || return
  validate_xhttp_path "$xhttp_path" \
    || state_contract_fail "XHTTP path 不是安全绝对路径。" || return

  for token in \
    "$legacy_token" "$ipv4_token" "$ipv6_token" \
    "$ipv4_to_ipv6_token" "$ipv6_to_ipv4_token"; do
    [[ -n "$token" ]] || continue
    validate_urlsafe_secret "$token" \
      || state_contract_fail "订阅 Token 格式无效。" || return
  done
  if [[ "$anyreality_enabled" == true ]]; then
    validate_urlsafe_secret "$anyreality_password" \
      || state_contract_fail "AnyReality 密码格式无效。" || return
    validate_reality_key "$anyreality_private" \
      || state_contract_fail "AnyReality 私钥格式无效。" || return
    validate_reality_key "$anyreality_public" \
      || state_contract_fail "AnyReality 公钥格式无效。" || return
    validate_reality_short_id "$anyreality_short_id" \
      || state_contract_fail "AnyReality Short ID 格式无效。" || return
  fi
}

validate_state_file_port_layout() {
  local state_file="$1" schema mode raw_mode kind label first second port
  local state_metadata port_rows
  local -A seen_ports=()
  state_metadata="$(jq -r '[
      (if .schema == null then 1 else .schema end),
      (.network.mode // "")
    ] | join("\u001f")' "$state_file")" \
    || state_contract_fail "无法读取端口元数据。" || return
  IFS=$'\x1f' read -r schema raw_mode <<< "$state_metadata"
  if (( schema >= 3 )); then
    mode="$(normalize_network_mode "$raw_mode")" \
      || state_contract_fail "网络模式无效。" || return
  else
    mode="$NETWORK_MODE_DUAL"
  fi

  port_rows="$(jq -r --argjson schema "$schema" --arg mode "$mode" '
      (["range", "Hysteria2", .ports.hysteria2_start, .ports.hysteria2_end] | @tsv),
      (["port", "TUIC", .ports.tuic] | @tsv),
      (["port", "SS2022", .ports.ss2022] | @tsv),
      (["port", "AnyTLS", .ports.anytls] | @tsv),
      (if .ports.trojan != null then
        (["port", "Trojan", .ports.trojan] | @tsv) else empty end),
      (["port", "VLESS Vision", .ports.vless_reality_vision] | @tsv),
      (["port", "VLESS XHTTP", .ports.vless_reality_xhttp] | @tsv),
      (if $schema == 4 and $mode == "dual" then
        (["range", "跨族 Hysteria2", .ports.cross.hysteria2_start,
          .ports.cross.hysteria2_end] | @tsv),
        (["port", "跨族 TUIC", .ports.cross.tuic] | @tsv),
        (["port", "跨族 SS2022", .ports.cross.ss2022] | @tsv),
        (["port", "跨族 AnyTLS", .ports.cross.anytls] | @tsv),
        (["port", "跨族 Trojan", .ports.cross.trojan] | @tsv),
        (["port", "跨族 VLESS Vision", .ports.cross.vless_reality_vision] | @tsv),
        (["port", "跨族 VLESS XHTTP", .ports.cross.vless_reality_xhttp] | @tsv)
      else empty end),
      (if .experimental.anyreality.enabled == true then
        (["port", "AnyReality", .experimental.anyreality.port] | @tsv),
        (if $schema == 4 and $mode == "dual" then
          (["port", "跨族 AnyReality", .experimental.anyreality.cross_port] | @tsv)
        else empty end)
      else empty end)
    ' "$state_file")" \
    || state_contract_fail "无法读取端口布局。" || return

  while IFS=$'\t' read -r kind label first second; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      range)
        (( first >= 10000 && second <= 60000 && second - first == 127 )) \
          || state_contract_fail "${label} 必须是 10000-60000 内连续 128 个端口。" \
          || return
        for ((port = first; port <= second; port++)); do
          [[ -z "${seen_ports[$port]+x}" ]] \
            || state_contract_fail \
              "${label} 端口 ${port} 与 ${seen_ports[$port]} 冲突。" \
            || return
          seen_ports["$port"]="$label"
        done
        ;;
      port)
        (( first >= 10000 && first <= 60000 )) \
          || state_contract_fail "${label} 不在 10000-60000。" || return
        [[ -z "${seen_ports[$first]+x}" ]] \
          || state_contract_fail \
            "${label} 端口 ${first} 与 ${seen_ports[$first]} 冲突。" \
          || return
        seen_ports["$first"]="$label"
        ;;
      *) state_contract_fail "内部端口类型无效。" || return ;;
    esac
  done <<< "$port_rows"
}

validate_state_source_contract() {
  local state_file="$1" minimum_schema="${2:-1}" maximum_schema="${3:-$NEKO_STATE_SCHEMA}"
  local metadata schema domain email acme_method raw_network_mode network_mode
  local legacy_token ipv4_token ipv6_token ipv4_to_ipv6_token ipv6_to_ipv4_token token
  validate_state_json_types "$state_file" "$minimum_schema" "$maximum_schema" \
    || return
  validate_state_secret_contract "$state_file" || return
  validate_state_file_port_layout "$state_file" || return

  metadata="$(jq -r '[
      (if .schema == null then 1 else .schema end),
      .domain,
      .acme_email,
      (.acme.method // "http-01"),
      (.network.mode // ""),
      (.subscription.token // ""),
      (.subscription.ipv4_token // ""),
      (.subscription.ipv6_token // ""),
      (.subscription.ipv4_to_ipv6_token // ""),
      (.subscription.ipv6_to_ipv4_token // "")
    ] | join("\u001f")' "$state_file")" \
    || state_contract_fail "无法读取状态元数据。" || return
  IFS=$'\x1f' read -r \
    schema domain email acme_method raw_network_mode legacy_token \
    ipv4_token ipv6_token ipv4_to_ipv6_token ipv6_to_ipv4_token <<< "$metadata"
  validate_domain "$domain" || state_contract_fail "基础域名无效。" || return
  validate_email "$email" || state_contract_fail "ACME 邮箱无效。" || return
  normalize_acme_method "$acme_method" >/dev/null \
    || state_contract_fail "ACME 验证方式无效。" || return

  if (( schema >= 3 )); then
    network_mode="$(normalize_network_mode "$raw_network_mode")" \
      || state_contract_fail "网络模式无效。" || return
  else
    network_mode="$NETWORK_MODE_DUAL"
  fi
  if (( schema <= 2 )); then
    token="$legacy_token"
    validate_urlsafe_secret "$token" \
      || state_contract_fail "旧版订阅 Token 格式无效。" || return
  else
    if network_mode_has_ipv4 "$network_mode"; then
      token="$ipv4_token"
      validate_urlsafe_secret "$token" \
        || state_contract_fail "IPv4 订阅 Token 格式无效。" || return
    fi
    if network_mode_has_ipv6 "$network_mode"; then
      token="$ipv6_token"
      validate_urlsafe_secret "$token" \
        || state_contract_fail "IPv6 订阅 Token 格式无效。" || return
    fi
    if (( schema == 4 )) && network_mode_has_cross_routes "$network_mode"; then
      token="$ipv4_to_ipv6_token"
      validate_urlsafe_secret "$token" \
        || state_contract_fail "IPv4→IPv6 订阅 Token 格式无效。" || return
      token="$ipv6_to_ipv4_token"
      validate_urlsafe_secret "$token" \
        || state_contract_fail "IPv6→IPv4 订阅 Token 格式无效。" || return
    fi
  fi
}

migrate_1_to_2() {
  local source="" target="" acme_method=""
  local ipv4_domain="" ipv6_domain="" ipv4_address="" ipv6_address=""
  while (( $# > 0 )); do
    (( $# >= 2 )) \
      || state_contract_fail "migrate_1_to_2 选项缺少参数：$1" || return
    case "$1" in
      --source) source="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --acme-method) acme_method="$2"; shift 2 ;;
      --ipv4-domain) ipv4_domain="$2"; shift 2 ;;
      --ipv6-domain) ipv6_domain="$2"; shift 2 ;;
      --ipv4-address) ipv4_address="$2"; shift 2 ;;
      --ipv6-address) ipv6_address="$2"; shift 2 ;;
      *) state_contract_fail "migrate_1_to_2 未知选项：$1" || return ;;
    esac
  done
  [[ -n "$source" && -n "$target" && -n "$acme_method" \
    && -n "$ipv4_domain" && -n "$ipv6_domain" \
    && -n "$ipv4_address" && -n "$ipv6_address" ]] \
    || state_contract_fail "migrate_1_to_2 参数不完整。" || return
  normalize_acme_method "$acme_method" >/dev/null \
    || state_contract_fail "迁移 ACME 验证方式无效。" || return
  validate_domain "$ipv4_domain" && validate_domain "$ipv6_domain" \
    || state_contract_fail "迁移订阅域名无效。" || return
  is_ipv4_literal "$ipv4_address" \
    || state_contract_fail "迁移严格 IPv4 地址无效。" || return
  is_ipv6_literal "$ipv6_address" \
    || state_contract_fail "迁移严格 IPv6 地址无效。" || return

  state_migration_step "$source" "$target" 1 2 '
      .schema = 2
      | .acme = {method: $acme_method}
      | .network = {listen_address: "::"}
      | .subscription.ipv4_domain = $ipv4_domain
      | .subscription.ipv6_domain = $ipv6_domain
      | .subscription.ipv4_address = $ipv4_address
      | .subscription.ipv6_address = $ipv6_address
      | del(.subscription.shadowrocket_server)
      | .firewall = (.firewall // {})
      | .firewall.zones = (
          if (.firewall.zones | type) == "array" then .firewall.zones
          elif (.firewall.zone // "") != "" then [.firewall.zone]
          else [] end
        )
    ' \
    --arg acme_method "$acme_method" \
    --arg ipv4_domain "$ipv4_domain" \
    --arg ipv6_domain "$ipv6_domain" \
    --arg ipv4_address "$ipv4_address" \
    --arg ipv6_address "$ipv6_address"
}

migrate_2_to_3() {
  local source="" target="" network_mode=""
  local ipv4_domain="" ipv6_domain="" ipv4_address="" ipv6_address=""
  local trojan_port="" trojan_password=""
  while (( $# > 0 )); do
    (( $# >= 2 )) \
      || state_contract_fail "migrate_2_to_3 选项缺少参数：$1" || return
    case "$1" in
      --source) source="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --network-mode) network_mode="$2"; shift 2 ;;
      --ipv4-domain) ipv4_domain="$2"; shift 2 ;;
      --ipv6-domain) ipv6_domain="$2"; shift 2 ;;
      --ipv4-address) ipv4_address="$2"; shift 2 ;;
      --ipv6-address) ipv6_address="$2"; shift 2 ;;
      --trojan-port) trojan_port="$2"; shift 2 ;;
      --trojan-password) trojan_password="$2"; shift 2 ;;
      *) state_contract_fail "migrate_2_to_3 未知选项：$1" || return ;;
    esac
  done
  [[ -n "$source" && -n "$target" && -n "$network_mode" \
    && -n "$trojan_port" && -n "$trojan_password" ]] \
    || state_contract_fail "migrate_2_to_3 参数不完整。" || return
  network_mode="$(normalize_network_mode "$network_mode")" \
    || state_contract_fail "迁移网络模式无效。" || return
  [[ "$trojan_port" =~ ^[0-9]+$ ]] \
    || state_contract_fail "迁移 Trojan 端口格式无效。" || return
  (( trojan_port >= 10000 && trojan_port <= 60000 )) \
    || state_contract_fail "迁移 Trojan 端口范围无效。" || return
  validate_urlsafe_secret "$trojan_password" \
    || state_contract_fail "迁移 Trojan 密码无效。" || return
  if network_mode_has_ipv4 "$network_mode"; then
    validate_domain "$ipv4_domain" \
      || state_contract_fail "迁移 IPv4 订阅域名无效。" || return
    is_ipv4_literal "$ipv4_address" \
      || state_contract_fail "迁移严格 IPv4 地址无效。" || return
  fi
  if network_mode_has_ipv6 "$network_mode"; then
    validate_domain "$ipv6_domain" \
      || state_contract_fail "迁移 IPv6 订阅域名无效。" || return
    is_ipv6_literal "$ipv6_address" \
      || state_contract_fail "迁移严格 IPv6 地址无效。" || return
  fi

  state_migration_step "$source" "$target" 2 3 '
      (.subscription.token // "") as $legacy_token
      | .schema = 3
      | .network = {mode: $network_mode}
      | .ports.trojan = (.ports.trojan // $trojan_port)
      | .ports.cross = null
      | .credentials.trojan_password = (
          .credentials.trojan_password // $trojan_password
        )
      | .subscription.ipv4_token = (
          if $network_mode == "ipv4-only" or $network_mode == "dual"
          then (.subscription.ipv4_token // $legacy_token)
          else null end
        )
      | .subscription.ipv6_token = (
          if $network_mode == "ipv6-only" or $network_mode == "dual"
          then (.subscription.ipv6_token // $legacy_token)
          else null end
        )
      | .subscription.ipv4_to_ipv6_token = null
      | .subscription.ipv6_to_ipv4_token = null
      | .subscription.ipv4_domain = (
          if $network_mode == "ipv4-only" or $network_mode == "dual"
          then $ipv4_domain else null end
        )
      | .subscription.ipv6_domain = (
          if $network_mode == "ipv6-only" or $network_mode == "dual"
          then $ipv6_domain else null end
        )
      | .subscription.ipv4_address = (
          if $network_mode == "ipv4-only" or $network_mode == "dual"
          then $ipv4_address else null end
        )
      | .subscription.ipv6_address = (
          if $network_mode == "ipv6-only" or $network_mode == "dual"
          then $ipv6_address else null end
        )
      | del(.subscription.token)
      | del(.subscription.shadowrocket_server)
    ' \
    --arg network_mode "$network_mode" \
    --arg ipv4_domain "$ipv4_domain" \
    --arg ipv6_domain "$ipv6_domain" \
    --arg ipv4_address "$ipv4_address" \
    --arg ipv6_address "$ipv6_address" \
    --argjson trojan_port "$trojan_port" \
    --arg trojan_password "$trojan_password"
}

migrate_3_to_4() {
  local source="" target="" network_mode="" anyreality_enabled
  local cross_hy2_start="" cross_hy2_end="" cross_tuic_port=""
  local cross_ss_port="" cross_anytls_port="" cross_trojan_port=""
  local cross_vision_port="" cross_xhttp_port="" cross_anyreality_port=""
  local ipv4_to_ipv6_token="" ipv6_to_ipv4_token="" port
  while (( $# > 0 )); do
    (( $# >= 2 )) \
      || state_contract_fail "migrate_3_to_4 选项缺少参数：$1" || return
    case "$1" in
      --source) source="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --cross-hysteria2-start) cross_hy2_start="$2"; shift 2 ;;
      --cross-hysteria2-end) cross_hy2_end="$2"; shift 2 ;;
      --cross-tuic-port) cross_tuic_port="$2"; shift 2 ;;
      --cross-ss2022-port) cross_ss_port="$2"; shift 2 ;;
      --cross-anytls-port) cross_anytls_port="$2"; shift 2 ;;
      --cross-trojan-port) cross_trojan_port="$2"; shift 2 ;;
      --cross-vision-port) cross_vision_port="$2"; shift 2 ;;
      --cross-xhttp-port) cross_xhttp_port="$2"; shift 2 ;;
      --cross-anyreality-port) cross_anyreality_port="$2"; shift 2 ;;
      --ipv4-to-ipv6-token) ipv4_to_ipv6_token="$2"; shift 2 ;;
      --ipv6-to-ipv4-token) ipv6_to_ipv4_token="$2"; shift 2 ;;
      *) state_contract_fail "migrate_3_to_4 未知选项：$1" || return ;;
    esac
  done
  [[ -n "$source" && -n "$target" ]] \
    || state_contract_fail "migrate_3_to_4 参数不完整。" || return
  state_validate_exact_schema "$source" 3 || return
  network_mode="$(jq -r '.network.mode // empty' "$source")"
  network_mode="$(normalize_network_mode "$network_mode")" \
    || state_contract_fail "迁移网络模式无效。" || return
  anyreality_enabled="$(
    jq -r '.experimental.anyreality.enabled // false' "$source"
  )"
  if network_mode_has_cross_routes "$network_mode"; then
    [[ -n "$cross_hy2_start" && -n "$cross_hy2_end" \
      && -n "$cross_tuic_port" && -n "$cross_ss_port" \
      && -n "$cross_anytls_port" && -n "$cross_trojan_port" \
      && -n "$cross_vision_port" && -n "$cross_xhttp_port" \
      && -n "$ipv4_to_ipv6_token" && -n "$ipv6_to_ipv4_token" ]] \
      || state_contract_fail "双栈 3→4 迁移参数不完整。" || return
    for port in \
      "$cross_hy2_start" "$cross_hy2_end" "$cross_tuic_port" \
      "$cross_ss_port" "$cross_anytls_port" "$cross_trojan_port" \
      "$cross_vision_port" "$cross_xhttp_port"; do
      [[ "$port" =~ ^[0-9]+$ ]] \
        || state_contract_fail "跨族迁移端口格式无效。" || return
    done
    (( cross_hy2_start >= 10000 && cross_hy2_end <= 60000 \
      && cross_hy2_end - cross_hy2_start == 127 )) \
      || state_contract_fail "跨族迁移 Hysteria2 端口范围无效。" || return
    validate_urlsafe_secret "$ipv4_to_ipv6_token" \
      || state_contract_fail "IPv4→IPv6 迁移 Token 无效。" || return
    validate_urlsafe_secret "$ipv6_to_ipv4_token" \
      || state_contract_fail "IPv6→IPv4 迁移 Token 无效。" || return
    if [[ "$anyreality_enabled" == true ]]; then
      [[ "$cross_anyreality_port" =~ ^[0-9]+$ ]] \
        || state_contract_fail "跨族 AnyReality 迁移端口无效。" || return
    else
      cross_anyreality_port="null"
    fi
  else
    cross_hy2_start="null"
    cross_hy2_end="null"
    cross_tuic_port="null"
    cross_ss_port="null"
    cross_anytls_port="null"
    cross_trojan_port="null"
    cross_vision_port="null"
    cross_xhttp_port="null"
    cross_anyreality_port="null"
  fi

  state_migration_step "$source" "$target" 3 4 '
      .schema = 4
      | .ports.cross = (
          if $network_mode == "dual" then
            (.ports.cross // {
              hysteria2_start: $cross_hy2_start,
              hysteria2_end: $cross_hy2_end,
              tuic: $cross_tuic_port,
              ss2022: $cross_ss_port,
              anytls: $cross_anytls_port,
              trojan: $cross_trojan_port,
              vless_reality_vision: $cross_vision_port,
              vless_reality_xhttp: $cross_xhttp_port
            })
          else null end
        )
      | .subscription.ipv4_to_ipv6_token = (
          if $network_mode == "dual"
          then (.subscription.ipv4_to_ipv6_token // $ipv4_to_ipv6_token)
          else null end
        )
      | .subscription.ipv6_to_ipv4_token = (
          if $network_mode == "dual"
          then (.subscription.ipv6_to_ipv4_token // $ipv6_to_ipv4_token)
          else null end
        )
      | if .experimental.anyreality.enabled == true then
          .experimental.anyreality.cross_port = (
            if $network_mode == "dual"
            then (.experimental.anyreality.cross_port // $cross_anyreality_port)
            else null end
          )
        else . end
    ' \
    --arg network_mode "$network_mode" \
    --argjson cross_hy2_start "$cross_hy2_start" \
    --argjson cross_hy2_end "$cross_hy2_end" \
    --argjson cross_tuic_port "$cross_tuic_port" \
    --argjson cross_ss_port "$cross_ss_port" \
    --argjson cross_anytls_port "$cross_anytls_port" \
    --argjson cross_trojan_port "$cross_trojan_port" \
    --argjson cross_vision_port "$cross_vision_port" \
    --argjson cross_xhttp_port "$cross_xhttp_port" \
    --argjson cross_anyreality_port "$cross_anyreality_port" \
    --arg ipv4_to_ipv6_token "$ipv4_to_ipv6_token" \
    --arg ipv6_to_ipv4_token "$ipv6_to_ipv4_token"
}

state_finalize_current_schema() {
  local source="" target="" release="" acme_method=""
  local ipv4_domain="" ipv6_domain="" ipv4_address="" ipv6_address=""
  local trojan_port="" trojan_password="" network_mode=""
  local anyreality_port="" cross_anyreality_port=""
  local anyreality_password="" anyreality_private="" anyreality_public=""
  local anyreality_short_id=""
  while (( $# > 0 )); do
    (( $# >= 2 )) \
      || state_contract_fail \
        "state_finalize_current_schema 选项缺少参数：$1" || return
    case "$1" in
      --source) source="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --release) release="$2"; shift 2 ;;
      --acme-method) acme_method="$2"; shift 2 ;;
      --ipv4-domain) ipv4_domain="$2"; shift 2 ;;
      --ipv6-domain) ipv6_domain="$2"; shift 2 ;;
      --ipv4-address) ipv4_address="$2"; shift 2 ;;
      --ipv6-address) ipv6_address="$2"; shift 2 ;;
      --trojan-port) trojan_port="$2"; shift 2 ;;
      --trojan-password) trojan_password="$2"; shift 2 ;;
      --anyreality-port) anyreality_port="$2"; shift 2 ;;
      --cross-anyreality-port) cross_anyreality_port="$2"; shift 2 ;;
      --anyreality-password) anyreality_password="$2"; shift 2 ;;
      --anyreality-private-key) anyreality_private="$2"; shift 2 ;;
      --anyreality-public-key) anyreality_public="$2"; shift 2 ;;
      --anyreality-short-id) anyreality_short_id="$2"; shift 2 ;;
      *) state_contract_fail "state_finalize_current_schema 未知选项：$1" || return ;;
    esac
  done
  [[ -n "$source" && -n "$target" && -n "$release" \
    && -n "$acme_method" && -n "$trojan_port" && -n "$trojan_password" \
    && -n "$anyreality_port" && -n "$anyreality_password" \
    && -n "$anyreality_private" && -n "$anyreality_public" \
    && -n "$anyreality_short_id" ]] \
    || state_contract_fail "当前 schema 收口参数不完整。" || return
  state_validate_exact_schema "$source" "$NEKO_STATE_SCHEMA" || return
  network_mode="$(jq -r '.network.mode // empty' "$source")"
  network_mode="$(normalize_network_mode "$network_mode")" \
    || state_contract_fail "当前 schema 网络模式无效。" || return
  normalize_acme_method "$acme_method" >/dev/null \
    || state_contract_fail "当前 schema ACME 验证方式无效。" || return
  [[ "$trojan_port" =~ ^[0-9]+$ && "$anyreality_port" =~ ^[0-9]+$ ]] \
    || state_contract_fail "当前 schema 新协议端口无效。" || return
  validate_urlsafe_secret "$trojan_password" \
    || state_contract_fail "当前 schema Trojan 密码无效。" || return
  validate_urlsafe_secret "$anyreality_password" \
    || state_contract_fail "当前 schema AnyReality 密码无效。" || return
  validate_reality_key "$anyreality_private" \
    && validate_reality_key "$anyreality_public" \
    && validate_reality_short_id "$anyreality_short_id" \
    || state_contract_fail "当前 schema AnyReality REALITY 凭据无效。" || return
  if network_mode_has_ipv4 "$network_mode"; then
    validate_domain "$ipv4_domain" && is_ipv4_literal "$ipv4_address" \
      || state_contract_fail "当前 schema IPv4 订阅端点无效。" || return
  fi
  if network_mode_has_ipv6 "$network_mode"; then
    validate_domain "$ipv6_domain" && is_ipv6_literal "$ipv6_address" \
      || state_contract_fail "当前 schema IPv6 订阅端点无效。" || return
  fi
  if network_mode_has_cross_routes "$network_mode"; then
    [[ "$cross_anyreality_port" =~ ^[0-9]+$ ]] \
      || state_contract_fail "当前 schema 跨族 AnyReality 端口无效。" || return
  else
    cross_anyreality_port="null"
  fi

  state_migration_step \
    "$source" "$target" "$NEKO_STATE_SCHEMA" "$NEKO_STATE_SCHEMA" '
      .schema = $schema
      | .release = $release
      | .acme = {method: $acme_method}
      | .ports.trojan = (.ports.trojan // $trojan_port)
      | .credentials.trojan_password = (
          .credentials.trojan_password // $trojan_password
        )
      | .experimental.anyreality = (
          if .experimental.anyreality.enabled == true then
            .experimental.anyreality
          else {
            enabled: true,
            port: $anyreality_port,
            cross_port: (
              if $network_mode == "dual" then $cross_anyreality_port else null end
            ),
            password: $anyreality_password,
            private_key: $anyreality_private,
            public_key: $anyreality_public,
            short_id: $anyreality_short_id
          } end
        )
      | .subscription.ipv4_domain = (
          if $network_mode == "ipv4-only" or $network_mode == "dual"
          then $ipv4_domain else null end
        )
      | .subscription.ipv6_domain = (
          if $network_mode == "ipv6-only" or $network_mode == "dual"
          then $ipv6_domain else null end
        )
      | .subscription.ipv4_address = (
          if $network_mode == "ipv4-only" or $network_mode == "dual"
          then $ipv4_address else null end
        )
      | .subscription.ipv6_address = (
          if $network_mode == "ipv6-only" or $network_mode == "dual"
          then $ipv6_address else null end
        )
      | del(.subscription.token)
      | del(.subscription.shadowrocket_server)
      | .firewall = (.firewall // {})
      | .firewall.zones = (
          if (.firewall.zones | type) == "array" then .firewall.zones
          elif (.firewall.zone // "") != "" then [.firewall.zone]
          else [] end
        )
    ' \
    --argjson schema "$NEKO_STATE_SCHEMA" \
    --arg release "$release" \
    --arg acme_method "$acme_method" \
    --arg network_mode "$network_mode" \
    --arg ipv4_domain "$ipv4_domain" \
    --arg ipv6_domain "$ipv6_domain" \
    --arg ipv4_address "$ipv4_address" \
    --arg ipv6_address "$ipv6_address" \
    --argjson trojan_port "$trojan_port" \
    --arg trojan_password "$trojan_password" \
    --argjson anyreality_port "$anyreality_port" \
    --argjson cross_anyreality_port "$cross_anyreality_port" \
    --arg anyreality_password "$anyreality_password" \
    --arg anyreality_private "$anyreality_private" \
    --arg anyreality_public "$anyreality_public" \
    --arg anyreality_short_id "$anyreality_short_id"
}

state_migrate_to_current() (
  local source="" target="" release="" acme_method="" network_mode=""
  local ipv4_domain="" ipv6_domain="" ipv4_address="" ipv6_address=""
  local trojan_port="" trojan_password=""
  local migration_cross_hy2_start="" migration_cross_hy2_end="" migration_cross_tuic_port=""
  local migration_cross_ss_port="" migration_cross_anytls_port="" migration_cross_trojan_port=""
  local migration_cross_vision_port="" migration_cross_xhttp_port=""
  local ipv4_to_ipv6_token="" ipv6_to_ipv4_token=""
  local anyreality_port="" cross_anyreality_port=""
  local anyreality_password="" anyreality_private="" anyreality_public=""
  local anyreality_short_id="" workdir="" current="" next="" schema

  while (( $# > 0 )); do
    (( $# >= 2 )) \
      || state_contract_fail "状态迁移选项 $1 缺少值。" || return
    case "$1" in
      --source) source="$2" ;;
      --target) target="$2" ;;
      --release) release="$2" ;;
      --acme-method) acme_method="$2" ;;
      --network-mode) network_mode="$2" ;;
      --ipv4-domain) ipv4_domain="$2" ;;
      --ipv6-domain) ipv6_domain="$2" ;;
      --ipv4-address) ipv4_address="$2" ;;
      --ipv6-address) ipv6_address="$2" ;;
      --trojan-port) trojan_port="$2" ;;
      --trojan-password) trojan_password="$2" ;;
      --cross-hysteria2-start) migration_cross_hy2_start="$2" ;;
      --cross-hysteria2-end) migration_cross_hy2_end="$2" ;;
      --cross-tuic-port) migration_cross_tuic_port="$2" ;;
      --cross-ss2022-port) migration_cross_ss_port="$2" ;;
      --cross-anytls-port) migration_cross_anytls_port="$2" ;;
      --cross-trojan-port) migration_cross_trojan_port="$2" ;;
      --cross-vision-port) migration_cross_vision_port="$2" ;;
      --cross-xhttp-port) migration_cross_xhttp_port="$2" ;;
      --ipv4-to-ipv6-token) ipv4_to_ipv6_token="$2" ;;
      --ipv6-to-ipv4-token) ipv6_to_ipv4_token="$2" ;;
      --anyreality-port) anyreality_port="$2" ;;
      --cross-anyreality-port) cross_anyreality_port="$2" ;;
      --anyreality-password) anyreality_password="$2" ;;
      --anyreality-private-key) anyreality_private="$2" ;;
      --anyreality-public-key) anyreality_public="$2" ;;
      --anyreality-short-id) anyreality_short_id="$2" ;;
      *) state_contract_fail "状态迁移未知选项：$1" || return ;;
    esac
    shift 2
  done

  [[ -n "$source" && -n "$target" && -n "$release" \
    && -n "$acme_method" && -n "$network_mode" ]] \
    || state_contract_fail "状态迁移总控参数不完整。" || return
  validate_state_source_contract "$source" 1 "$NEKO_STATE_SCHEMA" || return
  schema="$(state_schema_value "$source")" \
    || state_contract_fail "无法读取待迁移 schema。" || return
  workdir="$(mktemp -d "${target}.migration.XXXXXX")" || return
  trap '
    if [[ -n "${workdir:-}" && -n "${target:-}" \
      && "$workdir" == "${target}.migration."* ]]; then
      rm -rf -- "$workdir"
    fi
  ' EXIT
  current="$source"

  if (( schema == 1 )); then
    next="$workdir/schema2.json"
    migrate_1_to_2 \
      --source "$current" --target "$next" \
      --acme-method "$acme_method" \
      --ipv4-domain "$ipv4_domain" --ipv6-domain "$ipv6_domain" \
      --ipv4-address "$ipv4_address" --ipv6-address "$ipv6_address" \
      || return
    current="$next"
    schema=2
  fi
  if (( schema == 2 )); then
    next="$workdir/schema3.json"
    migrate_2_to_3 \
      --source "$current" --target "$next" \
      --network-mode "$network_mode" \
      --ipv4-domain "$ipv4_domain" --ipv6-domain "$ipv6_domain" \
      --ipv4-address "$ipv4_address" --ipv6-address "$ipv6_address" \
      --trojan-port "$trojan_port" --trojan-password "$trojan_password" \
      || return
    current="$next"
    schema=3
  fi
  if (( schema == 3 )); then
    next="$workdir/schema4.json"
    migrate_3_to_4 \
      --source "$current" --target "$next" \
      --cross-hysteria2-start "$migration_cross_hy2_start" \
      --cross-hysteria2-end "$migration_cross_hy2_end" \
      --cross-tuic-port "$migration_cross_tuic_port" \
      --cross-ss2022-port "$migration_cross_ss_port" \
      --cross-anytls-port "$migration_cross_anytls_port" \
      --cross-trojan-port "$migration_cross_trojan_port" \
      --cross-vision-port "$migration_cross_vision_port" \
      --cross-xhttp-port "$migration_cross_xhttp_port" \
      --cross-anyreality-port "$cross_anyreality_port" \
      --ipv4-to-ipv6-token "$ipv4_to_ipv6_token" \
      --ipv6-to-ipv4-token "$ipv6_to_ipv4_token" \
      || return
    current="$next"
    schema=4
  fi
  (( schema == NEKO_STATE_SCHEMA )) \
    || state_contract_fail "不支持迁移 state schema ${schema}。" || return

  next="$workdir/current.json"
  state_finalize_current_schema \
    --source "$current" --target "$next" \
    --release "$release" --acme-method "$acme_method" \
    --ipv4-domain "$ipv4_domain" --ipv6-domain "$ipv6_domain" \
    --ipv4-address "$ipv4_address" --ipv6-address "$ipv6_address" \
    --trojan-port "$trojan_port" --trojan-password "$trojan_password" \
    --anyreality-port "$anyreality_port" \
    --cross-anyreality-port "$cross_anyreality_port" \
    --anyreality-password "$anyreality_password" \
    --anyreality-private-key "$anyreality_private" \
    --anyreality-public-key "$anyreality_public" \
    --anyreality-short-id "$anyreality_short_id" \
    || return
  state_atomic_commit_candidate "$next" "$target" "$NEKO_STATE_SCHEMA"
)

load_state() {
  local state_schema expected_ipv4_domain expected_ipv6_domain
  [[ -r "$NEKO_STATE" ]] || die "找不到安装状态：${NEKO_STATE}"

  validate_state_source_contract "$NEKO_STATE" "$NEKO_STATE_SCHEMA" "$NEKO_STATE_SCHEMA" \
    || die "state.json 不符合 schema ${NEKO_STATE_SCHEMA} 的完整状态契约。"

  state_schema="$(state_value '.schema')"
  [[ "$state_schema" == "$NEKO_STATE_SCHEMA" ]] \
    || die "安装状态 schema 为 ${state_schema}；请先运行当前版本的升级脚本。"
  DOMAIN="$(state_value '.domain')"
  ACME_EMAIL="$(state_value '.acme_email')"
  validate_domain "$DOMAIN" || die "state.json 中的基础域名无效。"
  validate_email "$ACME_EMAIL" || die "state.json 中的 ACME 邮箱无效。"
  ACME_METHOD="$(jq -r '.acme.method // "http-01"' "$NEKO_STATE")"
  ACME_METHOD="$(normalize_acme_method "$ACME_METHOD")" \
    || die "state.json 中的 ACME 验证方式无效。"
  NETWORK_MODE="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
  NETWORK_MODE="$(normalize_network_mode "$NETWORK_MODE")" \
    || die "state.json 中的网络安装模式无效。"
  HY2_START="$(state_value '.ports.hysteria2_start')"
  HY2_END="$(state_value '.ports.hysteria2_end')"
  TUIC_PORT="$(state_value '.ports.tuic')"
  SS_PORT="$(state_value '.ports.ss2022')"
  ANYTLS_PORT="$(state_value '.ports.anytls')"
  TROJAN_PORT="$(state_value '.ports.trojan')"
  VISION_PORT="$(state_value '.ports.vless_reality_vision')"
  XHTTP_PORT="$(state_value '.ports.vless_reality_xhttp')"
  if network_mode_has_cross_routes; then
    CROSS_HY2_START="$(state_value '.ports.cross.hysteria2_start')"
    CROSS_HY2_END="$(state_value '.ports.cross.hysteria2_end')"
    CROSS_TUIC_PORT="$(state_value '.ports.cross.tuic')"
    CROSS_SS_PORT="$(state_value '.ports.cross.ss2022')"
    CROSS_ANYTLS_PORT="$(state_value '.ports.cross.anytls')"
    CROSS_TROJAN_PORT="$(state_value '.ports.cross.trojan')"
    CROSS_VISION_PORT="$(state_value '.ports.cross.vless_reality_vision')"
    CROSS_XHTTP_PORT="$(state_value '.ports.cross.vless_reality_xhttp')"
  else
    CROSS_HY2_START=""
    CROSS_HY2_END=""
    CROSS_TUIC_PORT=""
    CROSS_SS_PORT=""
    CROSS_ANYTLS_PORT=""
    CROSS_TROJAN_PORT=""
    CROSS_VISION_PORT=""
    CROSS_XHTTP_PORT=""
  fi
  ANYREALITY_ENABLED="$(jq -r '.experimental.anyreality.enabled // false' "$NEKO_STATE")"
  case "$ANYREALITY_ENABLED" in
    true)
      ANYREALITY_PORT="$(state_value '.experimental.anyreality.port')"
      ANYREALITY_PASSWORD="$(state_value '.experimental.anyreality.password')"
      ANYREALITY_PRIVATE_KEY="$(state_value '.experimental.anyreality.private_key')"
      ANYREALITY_PUBLIC_KEY="$(state_value '.experimental.anyreality.public_key')"
      ANYREALITY_SHORT_ID="$(state_value '.experimental.anyreality.short_id')"
      if network_mode_has_cross_routes; then
        CROSS_ANYREALITY_PORT="$(state_value '.experimental.anyreality.cross_port')"
      else
        CROSS_ANYREALITY_PORT=""
      fi
      [[ "$ANYREALITY_PASSWORD" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
        || die "state.json 中的 AnyReality 密码格式无效。"
      [[ "$ANYREALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] \
        || die "state.json 中的 AnyReality 私钥格式无效。"
      [[ "$ANYREALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] \
        || die "state.json 中的 AnyReality 公钥格式无效。"
      [[ "$ANYREALITY_SHORT_ID" =~ ^[0-9a-f]{16}$ ]] \
        || die "state.json 中的 AnyReality Short ID 格式无效。"
      ;;
    false)
      ANYREALITY_PORT=""
      CROSS_ANYREALITY_PORT=""
      ANYREALITY_PASSWORD=""
      ANYREALITY_PRIVATE_KEY=""
      ANYREALITY_PUBLIC_KEY=""
      ANYREALITY_SHORT_ID=""
      ;;
    *)
      die "state.json 中的 AnyReality 启用状态无效。"
      ;;
  esac
  validate_proxy_port_layout
  HY2_PASSWORD="$(state_value '.credentials.hysteria2_password')"
  HY2_OBFS_PASSWORD="$(state_value '.credentials.hysteria2_obfs_password')"
  TUIC_UUID="$(state_value '.credentials.tuic_uuid')"
  TUIC_PASSWORD="$(state_value '.credentials.tuic_password')"
  SS_PASSWORD="$(state_value '.credentials.ss2022_password')"
  ANYTLS_PASSWORD="$(state_value '.credentials.anytls_password')"
  TROJAN_PASSWORD="$(state_value '.credentials.trojan_password')"
  VISION_UUID="$(state_value '.credentials.vision_uuid')"
  XHTTP_UUID="$(state_value '.credentials.xhttp_uuid')"
  VISION_PRIVATE_KEY="$(state_value '.reality.vision_private_key')"
  VISION_PUBLIC_KEY="$(state_value '.reality.vision_public_key')"
  VISION_SHORT_ID="$(state_value '.reality.vision_short_id')"
  XHTTP_PRIVATE_KEY="$(state_value '.reality.xhttp_private_key')"
  XHTTP_PUBLIC_KEY="$(state_value '.reality.xhttp_public_key')"
  XHTTP_SHORT_ID="$(state_value '.reality.xhttp_short_id')"
  XHTTP_PATH="$(state_value '.reality.xhttp_path')"
  SUB_TOKEN_IPV4="$(jq -r '.subscription.ipv4_token // empty' "$NEKO_STATE")"
  SUB_TOKEN_IPV6="$(jq -r '.subscription.ipv6_token // empty' "$NEKO_STATE")"
  SUB_TOKEN_IPV4_TO_IPV6="$(jq -r '.subscription.ipv4_to_ipv6_token // empty' "$NEKO_STATE")"
  SUB_TOKEN_IPV6_TO_IPV4="$(jq -r '.subscription.ipv6_to_ipv4_token // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV4="$(jq -r '.subscription.ipv4_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV6="$(jq -r '.subscription.ipv6_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV4_ADDRESS="$(jq -r '.subscription.ipv4_address // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV6_ADDRESS="$(jq -r '.subscription.ipv6_address // empty' "$NEKO_STATE")"
  expected_ipv4_domain="v4.${DOMAIN}"
  expected_ipv6_domain="v6.${DOMAIN}"
  if network_mode_has_ipv4 "$NETWORK_MODE"; then
    [[ "$SUB_TOKEN_IPV4" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv4 订阅令牌格式无效。"
    validate_domain "$SUBSCRIPTION_DOMAIN_IPV4" \
      || die "state.json 中的 IPv4 订阅域名无效。"
    [[ "$SUBSCRIPTION_DOMAIN_IPV4" == "$expected_ipv4_domain" ]] \
      || die "state.json 中的 IPv4 订阅域名不是 ${expected_ipv4_domain}。"
    is_ipv4_literal "$SUBSCRIPTION_IPV4_ADDRESS" \
      || die "state.json 中的严格 IPv4 地址无效。"
  else
    SUB_TOKEN_IPV4=""
    SUBSCRIPTION_DOMAIN_IPV4=""
    SUBSCRIPTION_IPV4_ADDRESS=""
  fi
  if network_mode_has_ipv6 "$NETWORK_MODE"; then
    [[ "$SUB_TOKEN_IPV6" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv6 订阅令牌格式无效。"
    validate_domain "$SUBSCRIPTION_DOMAIN_IPV6" \
      || die "state.json 中的 IPv6 订阅域名无效。"
    [[ "$SUBSCRIPTION_DOMAIN_IPV6" == "$expected_ipv6_domain" ]] \
      || die "state.json 中的 IPv6 订阅域名不是 ${expected_ipv6_domain}。"
    is_ipv6_literal "$SUBSCRIPTION_IPV6_ADDRESS" \
      || die "state.json 中的严格 IPv6 地址无效。"
  else
    SUB_TOKEN_IPV6=""
    SUBSCRIPTION_DOMAIN_IPV6=""
    SUBSCRIPTION_IPV6_ADDRESS=""
  fi
  if network_mode_has_cross_routes; then
    [[ "$SUB_TOKEN_IPV4_TO_IPV6" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv4→IPv6 订阅令牌格式无效。"
    [[ "$SUB_TOKEN_IPV6_TO_IPV4" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv6→IPv4 订阅令牌格式无效。"
  else
    SUB_TOKEN_IPV4_TO_IPV6=""
    SUB_TOKEN_IPV6_TO_IPV4=""
  fi
  CERT_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.crt"
  KEY_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.key"
}
