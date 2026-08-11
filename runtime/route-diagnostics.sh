#!/usr/bin/env bash

# Read-only six-region, three-carrier route diagnostics extracted from Neko's
# former full health report.  This component contains no hardware benchmark,
# IP-quality, BGP-registration or general system-diagnostics menu.

set -uo pipefail
umask 0077
export LC_ALL=C

NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_DIAG_TMP_DIR="${NEKO_DIAG_TMP_DIR:-/var/tmp}"
NEKO_DIAG_NEXTTRACE="${NEKO_DIAG_NEXTTRACE:-${NEKO_LIBEXEC}/nexttrace-tiny}"
NEKO_DIAG_ROUTE_TIMEOUT="${NEKO_DIAG_ROUTE_TIMEOUT:-35}"
NEKO_DIAG_ROUTE_PROVIDER="${NEKO_DIAG_ROUTE_PROVIDER:-LeoMoeAPI}"
NEKO_DIAG_ROUTE_REGION="${NEKO_DIAG_ROUTE_REGION:-gd}"
NEKO_DIAG_PING="${NEKO_DIAG_PING:-ping}"
NEKO_DIAG_PACKET_LOSS_COUNT=100
NEKO_DIAG_PACKET_LOSS_INTERVAL=0.2
NEKO_DIAG_PACKET_LOSS_TIMEOUT=33
NEKO_DIAG_ROUTE_PREFLIGHT_COUNT=3
NEKO_DIAG_ROUTE_PREFLIGHT_INTERVAL=0.2
NEKO_DIAG_ROUTE_PREFLIGHT_TIMEOUT=7
NEKO_DIAG_TCP_CONNECT_COUNT=100
NEKO_DIAG_TCP_PREFLIGHT_COUNT=3
NEKO_DIAG_TCP_CONNECT_TIMEOUT="${NEKO_DIAG_TCP_CONNECT_TIMEOUT:-2}"
NEKO_DIAG_TCP_ATTEMPT_TIMEOUT="${NEKO_DIAG_TCP_ATTEMPT_TIMEOUT:-3}"
NEKO_DIAG_TCP_INTERVAL="${NEKO_DIAG_TCP_INTERVAL:-0.1}"
NEKO_DIAG_TCP_PORTS="${NEKO_DIAG_TCP_PORTS:-443 80}"
NEKO_DIAG_TCP_CURL="${NEKO_DIAG_TCP_CURL:-curl}"
NEKO_DIAG_ROUTE_V4_CT="${NEKO_DIAG_ROUTE_V4_CT:-gd-ct-v4.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V4_CU="${NEKO_DIAG_ROUTE_V4_CU:-gd-cu-v4.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V4_CM="${NEKO_DIAG_ROUTE_V4_CM:-gd-cm-v4.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V6_CT="${NEKO_DIAG_ROUTE_V6_CT:-gd-ct-v6.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V6_CU="${NEKO_DIAG_ROUTE_V6_CU:-gd-cu-v6.ip.zstaticcdn.com}"
NEKO_DIAG_ROUTE_V6_CM="${NEKO_DIAG_ROUTE_V6_CM:-gd-cm-v6.ip.zstaticcdn.com}"

# shellcheck source=lib/common.sh
source "${NEKO_LIBEXEC}/lib/common.sh"

DIAG_ROUTE_DIR=""
DIAG_OWNER_BASHPID="$BASHPID"
ROUTE_COMPLETED_COUNT=0
ROUTE_FAILED_COUNT=0
ICMP_SAMPLE_COMPLETED_COUNT=0
TCP_SAMPLE_COMPLETED_COUNT=0
QUALITY_SAMPLE_FAILED_COUNT=0
ROUTE_REPORT_HAS_SUMMARY=0
ROUTE_TRACE_AVAILABLE=0
ROUTE_PACKET_LOSS_AVAILABLE=0
ROUTE_TCP_AVAILABLE=0

diag_cleanup() {
  local base="${NEKO_DIAG_TMP_DIR%/}"
  # Process substitutions inherit EXIT traps.  Only the shell running the
  # report owns its temporary directory; parser children must leave it alone.
  [[ "$BASHPID" == "$DIAG_OWNER_BASHPID" ]] || return 0
  if [[ -n "$DIAG_ROUTE_DIR" && -n "$base" \
    && "$DIAG_ROUTE_DIR" == "$base"/.neko-route.* ]]; then
    rm -rf -- "$DIAG_ROUTE_DIR"
  fi
  DIAG_ROUTE_DIR=""
}

trap diag_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

diag_skip() {
  printf '  [未测] %s\n' "$1"
}

load_diag_state() {
  [[ -r "$NEKO_STATE" ]] || return 1
  jq -e --argjson schema "$NEKO_STATE_SCHEMA" \
    '.schema == $schema and (.network.mode | type == "string")' \
    "$NEKO_STATE" >/dev/null 2>&1 || return 1

  DOMAIN="$(jq -r '.domain // empty' "$NEKO_STATE")"
  NETWORK_MODE="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
  NETWORK_MODE="$(normalize_network_mode "$NETWORK_MODE")" || return 1
  SUBSCRIPTION_DOMAIN_IPV4="$(jq -r '.subscription.ipv4_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_DOMAIN_IPV6="$(jq -r '.subscription.ipv6_domain // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV4_ADDRESS="$(jq -r '.subscription.ipv4_address // empty' "$NEKO_STATE")"
  SUBSCRIPTION_IPV6_ADDRESS="$(jq -r '.subscription.ipv6_address // empty' "$NEKO_STATE")"
  CERT_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.crt"
  KEY_FILE="${NEKO_VAR}/lego/certificates/${DOMAIN}.key"
  return 0
}

address_is_local() {
  local family="$1" address="$2" output=""
  case "$family" in
    ipv4)
      output="$(ip -4 -o address show to "${address}/32" 2>/dev/null || true)"
      ;;
    ipv6)
      output="$(ip -6 -o address show to "${address}/128" 2>/dev/null || true)"
      ;;
    *) return 1 ;;
  esac
  [[ -n "$output" ]]
}

run_nexttrace_probe() {
  local family="$1" source_address="$2" target="$3" output_file="$4"
  local target_port="${5:-80}"
  local family_flag timeout_seconds="$NEKO_DIAG_ROUTE_TIMEOUT"

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] \
    && (( timeout_seconds >= 10 && timeout_seconds <= 90 )) \
    || timeout_seconds=35
  if [[ "$family" == ipv4 ]]; then
    family_flag=--ipv4
  else
    family_flag=--ipv6
  fi
  timeout --kill-after=2 "$timeout_seconds" \
    "$NEKO_DIAG_NEXTTRACE" \
    "$family_flag" --tcp --port "$target_port" \
    --source "$source_address" \
    --queries 1 --max-attempts 2 --parallel-requests 6 \
    --max-hops 30 --timeout 1000 --send-time 50 --ttl-time 100 \
    --no-rdns --data-provider "$NEKO_DIAG_ROUTE_PROVIDER" \
    --json --map --no-color "$target" \
    > "$output_file" 2> "${output_file}.err"
}

run_packet_loss_probe() {
  local family="$1" source_address="$2" target="$3" output_file="$4"
  local family_flag outer_timeout

  (( ROUTE_PACKET_LOSS_AVAILABLE == 1 )) || return 0
  if [[ "$family" == ipv4 ]]; then
    family_flag=-4
  else
    family_flag=-6
  fi
  outer_timeout="$NEKO_DIAG_PACKET_LOSS_TIMEOUT"
  # Do not add ping -w: combined with -c it may send past 100 after loss.
  timeout --kill-after=2 "$outer_timeout" \
    "$NEKO_DIAG_PING" "$family_flag" -n \
    -I "$source_address" \
    -c "$NEKO_DIAG_PACKET_LOSS_COUNT" \
    -i "$NEKO_DIAG_PACKET_LOSS_INTERVAL" \
    -W 1 \
    -- "$target" \
    > "$output_file" 2> "${output_file}.err"
}

run_route_preflight_probe() {
  local family="$1" source_address="$2" target="$3" output_file="$4"
  local family_flag

  (( ROUTE_PACKET_LOSS_AVAILABLE == 1 )) || return 0
  if [[ "$family" == ipv4 ]]; then
    family_flag=-4
  else
    family_flag=-6
  fi
  timeout --kill-after=2 "$NEKO_DIAG_ROUTE_PREFLIGHT_TIMEOUT" \
    "$NEKO_DIAG_PING" "$family_flag" -n -q \
    -I "$source_address" \
    -c "$NEKO_DIAG_ROUTE_PREFLIGHT_COUNT" \
    -i "$NEKO_DIAG_ROUTE_PREFLIGHT_INTERVAL" \
    -W 1 \
    -- "$target" \
    > "$output_file" 2> "${output_file}.err"
}

tcp_probe_ports() {
  local token result="" count=0
  local -a requested_ports=()

  read -r -a requested_ports <<< "$NEKO_DIAG_TCP_PORTS"
  for token in "${requested_ports[@]}"; do
    [[ "$token" =~ ^[0-9]+$ ]] || continue
    (( token >= 1 && token <= 65535 )) || continue
    [[ " $result " == *" $token "* ]] && continue
    printf '%s\n' "$token"
    result+=" ${token}"
    ((count += 1))
    (( count < 4 )) || break
  done
  (( count > 0 )) || printf '443\n80\n'
}

run_tcp_connect_attempt() {
  local family="$1" source_address="$2" target="$3" port="$4"
  local error_file="$5" family_flag scheme host connect_timeout attempt_timeout
  local output rc lookup connect latency
  local -a tls_args=()

  if [[ "$family" == ipv4 ]]; then
    family_flag=--ipv4
  else
    family_flag=--ipv6
  fi
  connect_timeout="$NEKO_DIAG_TCP_CONNECT_TIMEOUT"
  attempt_timeout="$NEKO_DIAG_TCP_ATTEMPT_TIMEOUT"
  [[ "$connect_timeout" =~ ^[0-9]+$ ]] \
    && (( connect_timeout >= 1 && connect_timeout <= 10 )) \
    || connect_timeout=2
  [[ "$attempt_timeout" =~ ^[0-9]+$ ]] \
    && (( attempt_timeout >= connect_timeout && attempt_timeout <= 15 )) \
    || attempt_timeout=$((connect_timeout + 1))
  (( attempt_timeout <= 15 )) || attempt_timeout=15

  host="$target"
  is_ipv6_literal "$target" && host="[${target}]"
  if [[ "$port" == 443 ]]; then
    scheme=https
    tls_args=(--insecure)
  else
    scheme=http
  fi

  output="$(
    timeout --kill-after=1 "${attempt_timeout}s" \
      "$NEKO_DIAG_TCP_CURL" --disable "$family_flag" --interface "$source_address" \
      --noproxy '*' --proto '=http,https' \
      --silent --show-error --output /dev/null --head \
      --connect-timeout "$connect_timeout" --max-time "$attempt_timeout" \
      --header 'Connection: close' "${tls_args[@]}" \
      --write-out $'%{time_namelookup}\t%{time_connect}\n' \
      "${scheme}://${host}:${port}/" \
      2>> "$error_file"
  )"
  rc=$?
  IFS=$'\t' read -r lookup connect <<< "$(
    awk -F '\t' '
      $1 ~ /^[0-9]+([.][0-9]+)?$/ \
        && $2 ~ /^[0-9]+([.][0-9]+)?$/ {line=$0}
      END {print line}' <<< "$output"
  )"
  if [[ "$lookup" =~ ^[0-9]+([.][0-9]+)?$ \
    && "$connect" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    latency="$(
      awk -v lookup="$lookup" -v connect="$connect" '
        BEGIN {
          milliseconds = (connect - lookup) * 1000
          if (connect <= 0 || milliseconds < 0) exit 1
          printf "%.2f", milliseconds
        }'
    )" || latency=""
    if [[ -n "$latency" ]]; then
      printf 'ok\t%s\n' "$latency"
      return 0
    fi
  fi
  printf 'fail\t%d\n' "$rc"
  return 0
}

run_tcp_preflight_probe() {
  local family="$1" source_address="$2" target="$3" port="$4"
  local output_file="$5" attempt

  : > "$output_file"
  for ((attempt = 1; attempt <= NEKO_DIAG_TCP_PREFLIGHT_COUNT; attempt++)); do
    run_tcp_connect_attempt \
      "$family" "$source_address" "$target" "$port" \
      "${output_file}.err" >> "$output_file"
  done
}

run_tcp_connection_probe() {
  local family="$1" source_address="$2" target="$3" port="$4"
  local output_file="$5" attempt interval

  interval="$NEKO_DIAG_TCP_INTERVAL"
  if [[ ! "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || ! awk -v value="$interval" \
      'BEGIN {exit !(value >= 0 && value <= 2)}'; then
    interval=0.1
  fi
  : > "$output_file"
  for ((attempt = 1; attempt <= NEKO_DIAG_TCP_CONNECT_COUNT; attempt++)); do
    run_tcp_connect_attempt \
      "$family" "$source_address" "$target" "$port" \
      "${output_file}.err" >> "$output_file"
    if (( attempt < NEKO_DIAG_TCP_CONNECT_COUNT )) \
      && [[ "$interval" != 0 && "$interval" != 0.0 ]]; then
      sleep "$interval" 2>/dev/null || true
    fi
  done
}

packet_loss_counts() {
  local file="$1" summary transmitted received

  [[ -s "$file" ]] || return 1
  summary="$(
    awk '/packets transmitted/ && /received/ {print; exit}' "$file" \
      2>/dev/null || true
  )"
  [[ -n "$summary" ]] || return 1
  transmitted="$(
    sed -nE \
      's/^[[:space:]]*([0-9]+) packets transmitted,.*/\1/p' \
      <<< "$summary"
  )"
  received="$(
    sed -nE \
      's/.*,[[:space:]]*([0-9]+)( packets)? received,.*/\1/p' \
      <<< "$summary"
  )"
  [[ "$transmitted" =~ ^[0-9]+$ && "$received" =~ ^[0-9]+$ ]] \
    || return 1
  (( received <= transmitted )) || return 1
  printf '%s\t%s\n' "$transmitted" "$received"
}

packet_latency_metrics() {
  local file="$1"

  [[ -s "$file" ]] || return 1
  awk '
    {
      for (field_index = 1; field_index <= NF; field_index++) {
        if ($field_index ~ /^time=[0-9]+([.][0-9]+)?$/) {
          value = $field_index
          sub(/^time=/, "", value)
          print value
        } else if ($field_index ~ /^time<[0-9]+([.][0-9]+)?$/) {
          value = $field_index
          sub(/^time</, "", value)
          # iputils commonly prints time<1 ms.  Use half of the bound instead
          # of pretending it was exactly zero or exactly the upper bound.
          printf "%.6f\n", value / 2
        }
      }
    }' "$file" 2>/dev/null \
    | sort -n \
    | awk '
      {
        samples[++count] = $1
        sum += $1
        sum_squared += $1 * $1
      }
      END {
        if (count < 1) exit 1
        if (count % 2 == 1) {
          p50 = samples[(count + 1) / 2]
        } else {
          p50 = (samples[count / 2] + samples[count / 2 + 1]) / 2
        }
        p95_index = int((95 * count + 99) / 100)
        variance = sum_squared / count - (sum / count) * (sum / count)
        if (variance < 0) variance = 0
        printf "%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%d\n", \
          samples[1], sum / count, p50, samples[p95_index], \
          samples[count], sqrt(variance), count
      }'
}

packet_loss_sample() {
  local file="$1" counts transmitted received loss

  counts="$(packet_loss_counts "$file")" || {
    if [[ -s "$file" ]]; then
      printf 'invalid\t测试异常（无法读取可靠统计）\n'
    else
      printf 'unavailable\t未测\n'
    fi
    return 0
  }
  IFS=$'\t' read -r transmitted received <<< "$counts"
  if (( transmitted != NEKO_DIAG_PACKET_LOSS_COUNT )); then
    printf 'invalid\t测试异常（发包统计 %d/%d）\n' \
      "$transmitted" "$NEKO_DIAG_PACKET_LOSS_COUNT"
    return 0
  fi
  loss=$((transmitted - received))
  if (( received == 0 )); then
    printf 'complete\t100%%（0/%d；本轮无 ICMP 响应）\n' \
      "$NEKO_DIAG_PACKET_LOSS_COUNT"
  else
    printf 'complete\t%d%%（%d/%d）\n' \
      "$loss" "$received" "$NEKO_DIAG_PACKET_LOSS_COUNT"
  fi
}

tcp_connection_counts() {
  local file="$1" attempts successful

  [[ -s "$file" ]] || return 1
  attempts="$(awk -F '\t' '$1 == "ok" || $1 == "fail" {count++} END {print count + 0}' "$file")"
  successful="$(awk -F '\t' '$1 == "ok" && $2 ~ /^[0-9]+([.][0-9]+)?$/ {count++} END {print count + 0}' "$file")"
  [[ "$attempts" =~ ^[0-9]+$ && "$successful" =~ ^[0-9]+$ ]] \
    || return 1
  (( successful <= attempts )) || return 1
  printf '%s\t%s\n' "$attempts" "$successful"
}

tcp_latency_metrics() {
  local file="$1"

  [[ -s "$file" ]] || return 1
  awk -F '\t' '
    $1 == "ok" && $2 ~ /^[0-9]+([.][0-9]+)?$/ {print $2}
  ' "$file" 2>/dev/null \
    | sort -n \
    | awk '
      {
        samples[++count] = $1
        sum += $1
      }
      END {
        if (count < 1) exit 1
        p95_index = int((95 * count + 99) / 100)
        printf "%.2f\t%.2f\t%d\n", sum / count, samples[p95_index], count
      }'
}

tcp_connection_sample() {
  local file="$1" counts attempts successful rate

  counts="$(tcp_connection_counts "$file")" || {
    if [[ -s "$file" ]]; then
      printf 'invalid\t测试异常（无法读取可靠 TCP 统计）\n'
    else
      printf 'unavailable\t未测\n'
    fi
    return 0
  }
  IFS=$'\t' read -r attempts successful <<< "$counts"
  if (( attempts != NEKO_DIAG_TCP_CONNECT_COUNT )); then
    printf 'invalid\t测试异常（TCP 尝试统计 %d/%d）\n' \
      "$attempts" "$NEKO_DIAG_TCP_CONNECT_COUNT"
    return 0
  fi
  rate=$((successful * 100 / attempts))
  printf 'complete\t%d%%（%d/%d）\n' \
    "$rate" "$successful" "$attempts"
}

normalize_route_region() {
  case "${1,,}" in
    ""|1|gd|guangdong|guangzhou)
      printf 'gd'
      ;;
    2|sh|shanghai)
      printf 'sh'
      ;;
    3|bj|beijing)
      printf 'bj'
      ;;
    4|sc|sichuan|cd|chengdu)
      printf 'sc'
      ;;
    5|hb|hubei)
      printf 'hb'
      ;;
    6|ln|liaoning)
      printf 'ln'
      ;;
    7|all)
      printf 'all'
      ;;
    *)
      return 1
      ;;
  esac
}

route_region_label() {
  case "$1" in
    gd) printf '广东' ;;
    sh) printf '上海' ;;
    bj) printf '北京' ;;
    sc) printf '四川' ;;
    hb) printf '湖北' ;;
    ln) printf '辽宁' ;;
    *) return 1 ;;
  esac
}

route_target() {
  local region="$1" family="$2" carrier="$3"
  local family_token override_name override_value legacy_value=""

  if [[ "$family" == ipv4 ]]; then
    family_token=V4
  else
    family_token=V6
  fi
  override_name="NEKO_DIAG_ROUTE_${region^^}_${family_token}_${carrier^^}"
  override_value="${!override_name:-}"
  if [[ -n "$override_value" ]]; then
    printf '%s' "$override_value"
    return 0
  fi

  # Keep the original Guangdong override names working for existing tests and
  # administrators who already use them.
  if [[ "$region" == gd ]]; then
    case "${family}:${carrier}" in
      ipv4:ct) legacy_value="$NEKO_DIAG_ROUTE_V4_CT" ;;
      ipv4:cu) legacy_value="$NEKO_DIAG_ROUTE_V4_CU" ;;
      ipv4:cm) legacy_value="$NEKO_DIAG_ROUTE_V4_CM" ;;
      ipv6:ct) legacy_value="$NEKO_DIAG_ROUTE_V6_CT" ;;
      ipv6:cu) legacy_value="$NEKO_DIAG_ROUTE_V6_CU" ;;
      ipv6:cm) legacy_value="$NEKO_DIAG_ROUTE_V6_CM" ;;
    esac
  fi
  if [[ -n "$legacy_value" ]]; then
    printf '%s' "$legacy_value"
  else
    printf '%s-%s-%s.ip.zstaticcdn.com' \
      "$region" "$carrier" "${family/ipv/v}"
  fi
}

route_backup_target() {
  local region="$1" family="$2" carrier="$3"
  local family_token override_name override_value legacy_name

  if [[ "$family" == ipv4 ]]; then
    family_token=V4
  else
    family_token=V6
  fi
  override_name="NEKO_DIAG_ROUTE_${region^^}_${family_token}_${carrier^^}_BACKUP"
  override_value="${!override_name:-}"
  if [[ -z "$override_value" && "$region" == gd ]]; then
    legacy_name="NEKO_DIAG_ROUTE_${family_token}_${carrier^^}_BACKUP"
    override_value="${!legacy_name:-}"
  fi
  printf '%s' "$override_value"
}

route_hostname_valid() {
  local value="$1"
  (( ${#value} >= 1 && ${#value} <= 253 )) || return 1
  [[ "$value" != *..* && "$value" != *.-* && "$value" != *-.* ]] \
    || return 1
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

route_target_valid() {
  local family="$1" value="$2"
  if [[ "$family" == ipv4 ]]; then
    is_ipv4_literal "$value" && return 0
    is_ipv6_literal "$value" && return 1
  else
    is_ipv6_literal "$value" && return 0
    is_ipv4_literal "$value" && return 1
  fi
  route_hostname_valid "$value"
}

route_target_candidates() {
  local region="$1" family="$2" carrier="$3"
  local primary backup

  primary="$(route_target "$region" "$family" "$carrier")"
  backup="$(route_backup_target "$region" "$family" "$carrier")"
  route_target_valid "$family" "$primary" && printf '%s\n' "$primary"
  if [[ -n "$backup" && "$backup" != "$primary" ]] \
    && route_target_valid "$family" "$backup"; then
    printf '%s\n' "$backup"
  fi
}

select_route_probe_target() {
  local region="$1" family="$2" carrier="$3" source_address="$4"
  local selection_file="$5" preflight_file="$6"
  local candidate candidate_file counts transmitted received index=0
  local port attempts successful
  local first_candidate="" primary backup
  local -a candidates=() ports=()

  primary="$(route_target "$region" "$family" "$carrier")"
  backup="$(route_backup_target "$region" "$family" "$carrier")"
  route_target_valid "$family" "$primary" && candidates+=("$primary")
  if [[ -n "$backup" && "$backup" != "$primary" ]] \
    && route_target_valid "$family" "$backup"; then
    candidates+=("$backup")
  fi
  (( ${#candidates[@]} > 0 )) || return 1
  first_candidate="${candidates[0]}"
  if (( ROUTE_PACKET_LOSS_AVAILABLE == 1 )); then
    index=0
    for candidate in "${candidates[@]}"; do
      ((index += 1))
      candidate_file="${preflight_file}.icmp-candidate-${index}"
      run_route_preflight_probe \
        "$family" "$source_address" "$candidate" "$candidate_file" || true
      counts="$(packet_loss_counts "$candidate_file")" || true
      [[ -n "$counts" ]] || continue
      IFS=$'\t' read -r transmitted received <<< "$counts"
      if (( transmitted == NEKO_DIAG_ROUTE_PREFLIGHT_COUNT \
        && received > 0 )); then
        mv -f -- "$candidate_file" "$preflight_file"
        printf '%s\ticmp\t0\t%d\t%d\n' \
          "$candidate" "$index" "${#candidates[@]}" > "$selection_file"
        return 0
      fi
    done
  fi

  if (( ROUTE_TCP_AVAILABLE == 1 )); then
    mapfile -t ports < <(tcp_probe_ports)
    index=0
    for candidate in "${candidates[@]}"; do
      ((index += 1))
      for port in "${ports[@]}"; do
        candidate_file="${preflight_file}.tcp-candidate-${index}-${port}"
        run_tcp_preflight_probe \
          "$family" "$source_address" "$candidate" "$port" \
          "$candidate_file"
        counts="$(tcp_connection_counts "$candidate_file")" || true
        [[ -n "$counts" ]] || continue
        IFS=$'\t' read -r attempts successful <<< "$counts"
        if (( attempts == NEKO_DIAG_TCP_PREFLIGHT_COUNT \
          && successful > 0 )); then
          printf '%s\ttcp\t%d\t%d\t%d\n' \
            "$candidate" "$port" "$index" "${#candidates[@]}" \
            > "$selection_file"
          return 0
        fi
      done
    done
  fi

  printf '%s\tunavailable\t0\t1\t%d\n' \
    "$first_candidate" "${#candidates[@]}" > "$selection_file"
  return 0
}

route_result_valid() {
  local file="$1"
  [[ -s "$file" ]] \
    && jq -e '.Hops | type == "array"' "$file" >/dev/null 2>&1
}

route_asn_path() {
  local file="$1"
  jq -r '
    def asn:
      tostring
      | ascii_upcase
      | sub("^AS"; "")
      | select(test("^[0-9]+$"))
      | "AS" + .;
    reduce (
      .Hops[][]?
      | select(.Success == true)
      | .Geo.asnumber?
      | select(. != null and . != "")
      | asn
    ) as $item (
      [];
      if index($item) == null then . + [$item] else . end
    )
    | join(" → ")' "$file" 2>/dev/null
}

known_carrier_network_label() {
  case "$1" in
    AS4809) printf 'CN2（AS4809）' ;;
    AS4134) printf '电信 163（AS4134）' ;;
    AS9929) printf '联通 9929/CUII（AS9929）' ;;
    AS4837) printf '联通 169（AS4837）' ;;
    AS10099) printf '中国联通国际（AS10099）' ;;
    AS23764) printf '中国电信国际 CTGNet（AS23764）' ;;
    AS58807) printf '移动 CMIN2（AS58807）' ;;
    AS58453) printf '中国移动国际 CMI（AS58453）' ;;
    AS9808) printf '移动 CMNET（AS9808）' ;;
    *) return 1 ;;
  esac
}

known_major_network_label() {
  # Stable short names for common global and East-Asian networks. This list is
  # intentionally not exhaustive; unknown ASNs remain visible in the raw path.
  case "$1" in
    AS174) printf 'Cogent（AS174）' ;;
    AS701) printf 'Verizon（AS701）' ;;
    AS1221) printf 'Telstra（AS1221）' ;;
    AS1239) printf 'SprintLink（AS1239）' ;;
    AS1299) printf 'Arelion（AS1299）' ;;
    AS2497) printf 'IIJ（AS2497）' ;;
    AS2516) printf 'KDDI（AS2516）' ;;
    AS2914) printf 'NTT（AS2914）' ;;
    AS3257) printf 'GTT（AS3257）' ;;
    AS3320) printf 'Deutsche Telekom（AS3320）' ;;
    AS3356) printf 'Level 3（AS3356）' ;;
    AS3462) printf 'HiNet（AS3462）' ;;
    AS3491) printf 'PCCW Global（AS3491）' ;;
    AS3549) printf 'Level 3（AS3549）' ;;
    AS3786) printf 'LG U+（AS3786）' ;;
    AS4637) printf 'Telstra Global（AS4637）' ;;
    AS4725) printf 'SoftBank ODN（AS4725）' ;;
    AS4766) printf 'Korea Telecom（AS4766）' ;;
    AS4826) printf 'Vocus（AS4826）' ;;
    AS5511) printf 'Orange OpenTransit（AS5511）' ;;
    AS6453) printf 'Tata Communications（AS6453）' ;;
    AS6461) printf 'Zayo（AS6461）' ;;
    AS6762) printf 'Sparkle（AS6762）' ;;
    AS6939) printf 'Hurricane Electric（AS6939）' ;;
    AS7018) printf 'AT&T（AS7018）' ;;
    AS7473) printf 'Singtel（AS7473）' ;;
    AS7474) printf 'Optus（AS7474）' ;;
    AS7578) printf 'GSL（AS7578）' ;;
    AS9002) printf 'RETN（AS9002）' ;;
    AS9304) printf 'HGC（AS9304）' ;;
    AS9318) printf 'SK Broadband（AS9318）' ;;
    AS10026) printf 'Telstra Global（AS10026）' ;;
    AS12956) printf 'Telxius（AS12956）' ;;
    AS17676) printf 'SoftBank（AS17676）' ;;
    AS136510) printf 'Streamline Servers（AS136510）' ;;
    AS137409) printf 'GSL Networks（AS137409）' ;;
    *) return 1 ;;
  esac
}

classify_major_networks() {
  local asn_path="$1" token label result="" count=0 omitted=0
  local -a path_tokens=()
  read -r -a path_tokens <<< "$asn_path"
  for token in "${path_tokens[@]}"; do
    label="$(known_major_network_label "$token")" || continue
    if (( count >= 8 )); then
      omitted=1
      continue
    fi
    [[ -z "$result" ]] || result+=" → "
    result+="$label"
    ((count += 1))
  done
  (( omitted == 0 )) || result+=" → …"
  printf '%s' "$result"
}

route_hop_count() {
  local file="$1"
  jq -r '
    [
      .Hops[]?
      | [.[]? | select(.Success == true)]
      | length
      | select(. > 0)
    ] | length' "$file" 2>/dev/null
}

classify_carrier_route() {
  local carrier="$1" asn_path="$2"
  local token label result=""
  local -a path_tokens=()

  # Preserve path order and show every recognized China-carrier network,
  # including the carrier's international and domestic backbone ASNs. Global
  # transit networks are classified separately.
  read -r -a path_tokens <<< "$asn_path"
  for token in "${path_tokens[@]}"; do
    label="$(known_carrier_network_label "$token")" || continue
    [[ -z "$result" ]] || result+=" → "
    result+="$label"
  done
  if [[ -n "$result" ]]; then
    printf '%s' "$result"
    return 0
  fi
  case "$carrier" in
    ct) printf '未识别常见电信骨干' ;;
    cu) printf '未识别常见联通骨干' ;;
    cm) printf '未识别常见移动骨干' ;;
  esac
}

show_carrier_route_result() {
  local region="$1" family="$2" carrier="$3" label="$4" file="$5"
  local packet_loss_file="$6" tcp_file="$7" selection_file="$8"
  local selected_target="" sample_method="unavailable" tcp_port=0
  local sample_status="unavailable" sample_display="未测" metrics=""
  local minimum average p50 p95 maximum variation response_count
  local asn_path="" major_networks="" carrier_network="" judgment="无法判断"
  local hop_count="" route_ok=0 label_color="$C_YELLOW"

  if [[ -s "$selection_file" ]]; then
    IFS=$'\t' read -r selected_target sample_method tcp_port _ _ \
      < "$selection_file"
  fi
  case "$sample_method" in
    icmp)
      IFS=$'\t' read -r sample_status sample_display \
        < <(packet_loss_sample "$packet_loss_file")
      if [[ "$sample_status" == complete ]]; then
        ((ICMP_SAMPLE_COMPLETED_COUNT += 1))
        metrics="$(packet_latency_metrics "$packet_loss_file")" || true
        if [[ -n "$metrics" ]]; then
          IFS=$'\t' read -r minimum average p50 p95 maximum variation \
            response_count <<< "$metrics"
        fi
      else
        ((QUALITY_SAMPLE_FAILED_COUNT += 1))
      fi
      ;;
    tcp)
      IFS=$'\t' read -r sample_status sample_display \
        < <(tcp_connection_sample "$tcp_file")
      if [[ "$sample_status" == complete ]]; then
        ((TCP_SAMPLE_COMPLETED_COUNT += 1))
        metrics="$(tcp_latency_metrics "$tcp_file")" || true
        if [[ -n "$metrics" ]]; then
          IFS=$'\t' read -r average p95 response_count <<< "$metrics"
        fi
      else
        ((QUALITY_SAMPLE_FAILED_COUNT += 1))
      fi
      ;;
    *)
      ((QUALITY_SAMPLE_FAILED_COUNT += 1))
      if (( ROUTE_PACKET_LOSS_AVAILABLE == 1 && ROUTE_TCP_AVAILABLE == 1 )); then
        sample_display="目标不响应 ICMP，TCP 端口也无法连接"
      elif (( ROUTE_PACKET_LOSS_AVAILABLE == 1 )); then
        sample_display="目标不响应 ICMP，系统缺少 TCP 测试工具"
      elif (( ROUTE_TCP_AVAILABLE == 1 )); then
        sample_display="目标 TCP 端口无法连接"
      else
        sample_display="系统缺少 ping 与 curl"
      fi
      ;;
  esac

  if route_result_valid "$file"; then
    hop_count="$(route_hop_count "$file")"
    if [[ "$hop_count" =~ ^[0-9]+$ ]] && (( hop_count > 0 )); then
      route_ok=1
      ((ROUTE_COMPLETED_COUNT += 1))
      asn_path="$(route_asn_path "$file")"
      if [[ -n "$asn_path" ]]; then
        carrier_network="$(classify_carrier_route "$carrier" "$asn_path")"
        major_networks="$(classify_major_networks "$asn_path")"
        judgment="$carrier_network"
        [[ -z "$major_networks" ]] || judgment="${major_networks} → ${judgment}"
      else
        judgment="路径有响应，但 ASN 暂不可用"
      fi
    fi
  fi
  if (( route_ok == 0 )); then
    ((ROUTE_FAILED_COUNT += 1))
  fi
  [[ "$sample_status" == complete || $route_ok == 1 ]] \
    && label_color="$C_GREEN"

  printf '  %s%s%s\n' "$label_color" "$label" "$C_RESET"
  case "$sample_method:$sample_status" in
    icmp:complete)
      if [[ -n "$metrics" ]]; then
        printf '        平均延迟：%s ms｜P95 延迟：%s ms\n' \
          "$average" "$p95"
      else
        printf '        平均延迟：未测（本轮没有收到 ICMP 响应）\n'
      fi
      printf '        ICMP 丢包率：%s\n' "$sample_display"
      ;;
    tcp:complete)
      if [[ -n "$metrics" ]]; then
        printf '        平均握手延迟：%s ms｜P95 握手延迟：%s ms\n' \
          "$average" "$p95"
      else
        printf '        平均握手延迟：未测（本轮没有成功连接）\n'
      fi
      printf '        TCP 连接成功率：%s（端口 %s）\n' \
        "$sample_display" "$tcp_port"
      ;;
    *)
      printf '        质量样本：未测（%s）\n' "$sample_display"
      ;;
  esac
  if (( route_ok == 1 )); then
    printf '        ASN 路径：%s（%s 跳响应）\n' \
      "${asn_path:-无 ASN 数据}" "$hop_count"
    printf '        线路判断：%s\n' "$judgment"
  else
    printf '        ASN 路径：未测（超时、无响应或线路元数据不可用）\n'
  fi
}

show_carrier_routes_for_family() {
  local region="$1" family="$2" source_address="$3"
  local selected_target sample_method tcp_port trace_port
  local -a carriers=(ct cu cm) labels=(电信 联通 移动)
  local -a files=() packet_loss_files=() tcp_files=() selection_files=() pids=()
  local index region_label pid

  region_label="$(route_region_label "$region")"
  files=(
    "${DIAG_ROUTE_DIR}/${region}-${family}-ct.json"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cu.json"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cm.json"
  )
  packet_loss_files=(
    "${DIAG_ROUTE_DIR}/${region}-${family}-ct.ping"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cu.ping"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cm.ping"
  )
  tcp_files=(
    "${DIAG_ROUTE_DIR}/${region}-${family}-ct.tcp"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cu.tcp"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cm.tcp"
  )
  selection_files=(
    "${DIAG_ROUTE_DIR}/${region}-${family}-ct.target"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cu.target"
    "${DIAG_ROUTE_DIR}/${region}-${family}-cm.target"
  )

  printf '\n%s【%s · %s 回程】%s\n' \
    "$C_BLUE" "$region_label" "${family/ipv/IPv}" "$C_RESET"
  for index in 0 1 2; do
    if (( ROUTE_PACKET_LOSS_AVAILABLE == 1 || ROUTE_TCP_AVAILABLE == 1 )); then
      # Keep target selection in the report owner shell.  Long 100-sample
      # probes still run in parallel; short preflights make fallback order
      # deterministic and avoid reporting an ICMP-blocking target as loss.
      select_route_probe_target \
        "$region" "$family" "${carriers[$index]}" "$source_address" \
        "${selection_files[$index]}" \
        "${packet_loss_files[$index]}.preflight" || true
    else
      selected_target="$(
        route_target_candidates \
          "$region" "$family" "${carriers[$index]}" \
          | awk 'NR == 1 {value=$0} END {if (value != "") print value}'
      )"
      if [[ -n "$selected_target" ]]; then
        printf '%s\tunavailable\t0\t1\t1\n' "$selected_target" \
          > "${selection_files[$index]}"
      fi
    fi
  done

  for index in 0 1 2; do
    selected_target=""
    sample_method="unavailable"
    tcp_port=0
    if [[ -s "${selection_files[$index]}" ]]; then
      IFS=$'\t' read -r selected_target sample_method tcp_port _ _ \
        < "${selection_files[$index]}"
    fi
    [[ -n "$selected_target" ]] || continue
    trace_port=80
    [[ "$tcp_port" =~ ^[0-9]+$ ]] && (( tcp_port > 0 )) \
      && trace_port="$tcp_port"
    if (( ROUTE_TRACE_AVAILABLE == 1 )); then
      (
        run_nexttrace_probe \
          "$family" "$source_address" "$selected_target" \
          "${files[$index]}" "$trace_port"
      ) &
      pids+=("$!")
    fi
    case "$sample_method" in
      icmp)
        (
          run_packet_loss_probe \
            "$family" "$source_address" "$selected_target" \
            "${packet_loss_files[$index]}"
        ) &
        pids+=("$!")
        ;;
      tcp)
        (
          run_tcp_connection_probe \
            "$family" "$source_address" "$selected_target" "$tcp_port" \
            "${tcp_files[$index]}"
        ) &
        pids+=("$!")
        ;;
    esac
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  for index in 0 1 2; do
    show_carrier_route_result \
      "$region" "$family" "${carriers[$index]}" "${labels[$index]}" \
      "${files[$index]}" "${packet_loss_files[$index]}" \
      "${tcp_files[$index]}" "${selection_files[$index]}"
  done
}

mark_route_family_unavailable() {
  local region="$1" family="$2" reason="$3"
  local region_label
  region_label="$(route_region_label "$region")"
  printf '\n%s【%s · %s 回程】%s\n' \
    "$C_BLUE" "$region_label" "${family/ipv/IPv}" "$C_RESET"
  printf '  [未测] %s\n' "$reason"
  ((ROUTE_FAILED_COUNT += 3))
  ((QUALITY_SAMPLE_FAILED_COUNT += 3))
}

show_route_report_summary() {
  ROUTE_REPORT_HAS_SUMMARY=1
  printf '\n%s========== 线路测试小结 ==========%s\n' \
    "$C_BLUE" "$C_RESET"
  printf '  ASN 路径：有效 %d 条，未测 %d 条。\n' \
    "$ROUTE_COMPLETED_COUNT" "$ROUTE_FAILED_COUNT"
  printf '  质量样本：ICMP %d 组，TCP %d 组，未测/异常 %d 组。\n' \
    "$ICMP_SAMPLE_COMPLETED_COUNT" "$TCP_SAMPLE_COMPLETED_COUNT" \
    "$QUALITY_SAMPLE_FAILED_COUNT"
  printf '  ICMP 每组固定发送 %d 包；不回应 ICMP 时改测 %d 次 TCP 连接。\n' \
    "$NEKO_DIAG_PACKET_LOSS_COUNT" "$NEKO_DIAG_TCP_CONNECT_COUNT"
  printf '  TCP 显示的是连接成功率，不冒充网络层丢包率。\n'
  printf '  这里只测 VPS → 国内参考目标的回程；ASN 判断仅作线路识别参考。\n'
}

show_route_report() {
  local requested_region="${1:-$NEKO_DIAG_ROUTE_REGION}"
  local selected_region region separator=""
  local -a regions=()

  selected_region="$(normalize_route_region "$requested_region")" || {
    warn "不支持的线路地区：${requested_region}。可用值：gd、sh、bj、sc、hb、ln、all。"
    return 2
  }
  if [[ "$selected_region" == all ]]; then
    regions=(gd sh bj sc hb ln)
  else
    regions=("$selected_region")
  fi
  ROUTE_COMPLETED_COUNT=0
  ROUTE_FAILED_COUNT=0
  ICMP_SAMPLE_COMPLETED_COUNT=0
  TCP_SAMPLE_COMPLETED_COUNT=0
  QUALITY_SAMPLE_FAILED_COUNT=0
  ROUTE_REPORT_HAS_SUMMARY=0
  ROUTE_TRACE_AVAILABLE=0
  ROUTE_PACKET_LOSS_AVAILABLE=0
  ROUTE_TCP_AVAILABLE=0

  printf '\n%s========== Neko 三网线路检测 ==========%s\n' \
    "$C_BLUE" "$C_RESET"
  if ! load_diag_state; then
    diag_skip "没有可用的 Neko 安装状态，无法绑定已安装地址族。"
    return 0
  fi
  if [[ -x "$NEKO_DIAG_NEXTTRACE" ]]; then
    ROUTE_TRACE_AVAILABLE=1
  else
    printf '  [未测] 可选 NextTrace 组件不可用；继续尝试 ICMP/TCP 质量样本。\n'
  fi
  if command -v "$NEKO_DIAG_PING" >/dev/null 2>&1; then
    ROUTE_PACKET_LOSS_AVAILABLE=1
  else
    printf '  [未测] 系统缺少 ping；质量样本将尝试 TCP 连接测试。\n'
  fi
  if command -v "$NEKO_DIAG_TCP_CURL" >/dev/null 2>&1; then
    ROUTE_TCP_AVAILABLE=1
  else
    printf '  [未测] 系统缺少 curl；ICMP 不回应时无法改测 TCP。\n'
  fi
  if (( ROUTE_TRACE_AVAILABLE == 0 \
    && ROUTE_PACKET_LOSS_AVAILABLE == 0 && ROUTE_TCP_AVAILABLE == 0 )); then
    diag_skip "NextTrace、ping 与 curl 都不可用；安装与代理服务不受影响。"
    return 0
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    diag_skip "系统缺少 timeout，未运行有严格时限的线路测试。"
    return 0
  fi
  if [[ ! -d "$NEKO_DIAG_TMP_DIR" || ! -w "$NEKO_DIAG_TMP_DIR" ]]; then
    diag_skip "临时目录不可写，未运行线路测试。"
    return 0
  fi
  DIAG_ROUTE_DIR="$(
    mktemp -d "${NEKO_DIAG_TMP_DIR%/}/.neko-route.XXXXXX"
  )" || {
    DIAG_ROUTE_DIR=""
    diag_skip "无法创建线路测试临时目录。"
    return 0
  }
  printf '  测试地区：'
  for region in "${regions[@]}"; do
    printf '%s%s' "$separator" "$(route_region_label "$region")"
    separator="、"
  done
  printf '\n'
  printf '  测试方向：%s回程%s（这台 VPS → 国内三网参考目标）。\n' \
    "$C_GREEN" "$C_RESET"
  if (( ROUTE_PACKET_LOSS_AVAILABLE == 1 )); then
    printf '  质量样本：先发 %d 包 ICMP 预检；通过后固定发送 %d 包。\n' \
      "$NEKO_DIAG_ROUTE_PREFLIGHT_COUNT" "$NEKO_DIAG_PACKET_LOSS_COUNT"
  else
    printf '  ICMP 样本：未运行（系统缺少 ping）。\n'
  fi
  if (( ROUTE_TCP_AVAILABLE == 1 )); then
    printf '  TCP 降级：ICMP 不回应时改测 %d 次独立连接，并显示成功率与握手延迟。\n' \
      "$NEKO_DIAG_TCP_CONNECT_COUNT"
  fi
  printf '  说明：TCP 成功率不是网络层丢包率；所有失败只会显示“未测”。\n'
  if ! network_mode_has_ipv4 "$NETWORK_MODE"; then
    printf '  [自动跳过] 当前 Neko 安装未配置可用 IPv4；只测试 IPv6，不会报错退出。\n'
  fi
  if ! network_mode_has_ipv6 "$NETWORK_MODE"; then
    printf '  [自动跳过] 当前 Neko 安装未配置可用 IPv6；只测试 IPv4，不会报错退出。\n'
  fi

  for region in "${regions[@]}"; do
    if network_mode_has_ipv4 "$NETWORK_MODE"; then
      if is_ipv4_literal "$SUBSCRIPTION_IPV4_ADDRESS" \
        && address_is_local ipv4 "$SUBSCRIPTION_IPV4_ADDRESS"; then
        show_carrier_routes_for_family \
          "$region" ipv4 "$SUBSCRIPTION_IPV4_ADDRESS"
      else
        mark_route_family_unavailable "$region" ipv4 \
          "IPv4 配置地址无效或已不属于本机。"
      fi
    fi
    if network_mode_has_ipv6 "$NETWORK_MODE"; then
      if is_ipv6_literal "$SUBSCRIPTION_IPV6_ADDRESS" \
        && address_is_local ipv6 "$SUBSCRIPTION_IPV6_ADDRESS"; then
        show_carrier_routes_for_family \
          "$region" ipv6 "$SUBSCRIPTION_IPV6_ADDRESS"
      else
        mark_route_family_unavailable "$region" ipv6 \
          "IPv6 配置地址无效或已不属于本机。"
      fi
    fi
  done
  rm -rf -- "$DIAG_ROUTE_DIR"
  DIAG_ROUTE_DIR=""
  show_route_report_summary
}

run_route_menu() {
  local choice selected_region answer region_text duration_text
  while true; do
    clear 2>/dev/null || true
    printf '%sNeko 三网线路检测%s\n' "$C_BLUE" "$C_RESET"
    printf '==================\n'
    printf '1. 广东\n'
    printf '2. 上海\n'
    printf '3. 北京\n'
    printf '4. 四川\n'
    printf '5. 湖北\n'
    printf '6. 辽宁\n'
    printf '7. 全部地区（六地）\n'
    printf '0. 返回\n\n'
    printf '说明：本机测试回程（VPS → 国内）；每个目标固定 100 个 ICMP 包，ICMP 不可用时改测 100 次 TCP 连接。\n\n'
    read -r -p "请选择 [0-7]：" choice
    case "$choice" in
      0|"") return 0 ;;
    esac
    selected_region="$(normalize_route_region "$choice")" || {
      warn "请输入 0 到 7。"
      sleep 1
      continue
    }
    if [[ "$selected_region" == all ]]; then
      region_text="广东、上海、北京、四川、湖北、辽宁"
      duration_text="通常约 4 分钟，连续超时时可能更久"
    else
      region_text="$(route_region_label "$selected_region")"
      duration_text="通常约 1 分钟，连续超时时可能更久"
    fi
    warn "将从 VPS 向${region_text}三网目标检测 ASN 线路、平均/P95 延迟和丢包；${duration_text}，不会修改 Neko 或系统配置。"
    read -r -p "输入 ROUTE 确认运行：" answer
    [[ "$answer" == ROUTE ]] || continue
    show_route_report "$selected_region"
    printf '\n'
    read -r -p "按 Enter 返回线路地区菜单……" _ || true
  done
}

usage() {
  cat <<'EOF'
用法：
  route-diagnostics.sh
  route-diagnostics.sh --region gd|sh|bj|sc|hb|ln|all
EOF
}

main() {
  case "${1:-}" in
    "")
      run_route_menu
      ;;
    --region)
      [[ $# -eq 2 ]] || { usage >&2; return 2; }
      show_route_report "$2"
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
