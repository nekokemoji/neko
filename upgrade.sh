#!/usr/bin/env bash

# Upgrade an existing Neko installation to the current address-family-aware
# layout. Protocol credentials, ports, installed families and subscription
# URLs are preserved. Every changed file, unit and certificate is backed up.

set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NEKO_ETC="${NEKO_ETC:-/etc/neko}"
NEKO_VAR="${NEKO_VAR:-/var/lib/neko}"
NEKO_LIBEXEC="${NEKO_LIBEXEC:-/usr/local/libexec/neko}"
NEKO_SYSTEMD="${NEKO_SYSTEMD:-/etc/systemd/system}"
NEKO_STATE="${NEKO_STATE:-${NEKO_ETC}/state.json}"
NEKO_USER="${NEKO_USER:-neko-proxy}"
NEKO_UPDATE_TMP_DIR="${NEKO_UPDATE_TMP_DIR:-/var/tmp}"
NEKO_UPDATE_LOCK_FILE="${NEKO_UPDATE_LOCK_FILE:-/run/lock/neko-maintenance.lock}"
BACKUP_DIR=""
QRC_STAGE_DIR=""
QRC_STAGED_BINARY=""
NEXTTRACE_STAGE_DIR=""
NEXTTRACE_STAGED_BINARY=""
CORE_STAGE_DIR=""
CORE_STAGE_BIN_DIR=""
CORE_TARGET_MANIFEST=""
CORE_UPGRADE_REQUIRED=0
CORE_ARCH=""
CORE_ARCH_KEY=""
CORE_ACTIVATION_TEMPS=()
ROLLBACK_READY=0
UPGRADE_FIREWALL_MANAGER="none"
export NEKO_ETC NEKO_VAR NEKO_LIBEXEC NEKO_SYSTEMD NEKO_STATE NEKO_USER

# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/firewall.sh
source "$SCRIPT_DIR/lib/firewall.sh"

cleanup_backup() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  if [[ -n "$BACKUP_DIR" && "$BACKUP_DIR" == "$base"/neko-upgrade-backup.* ]]; then
    rm -rf -- "$BACKUP_DIR"
  fi
}

cleanup_qrc_stage() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  [[ -n "$QRC_STAGE_DIR" ]] || return 0
  if [[ -n "$base" && "$QRC_STAGE_DIR" == "$base"/neko-qrc-stage.* ]]; then
    rm -rf -- "$QRC_STAGE_DIR"
    QRC_STAGE_DIR=""
    QRC_STAGED_BINARY=""
  fi
}

stage_optional_qrc() {
  local qrc_source="${NEKO_UPDATE_QRC_BINARY:-}"
  local qrc_asset qrc_archive qrc_help

  case "${ARCH_OVERRIDE:-$(uname -m)}" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)
      warn "当前 CPU 没有匹配的 qrc；升级仍会继续，文字订阅链接不受影响。"
      return 0
      ;;
  esac
  export ARCH

  if ! QRC_STAGE_DIR="$(
      mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-qrc-stage.XXXXXX"
    )"; then
    QRC_STAGE_DIR=""
    warn "无法创建 qrc 临时目录；升级仍会继续，文字订阅链接不受影响。"
    return 0
  fi
  QRC_STAGED_BINARY="${QRC_STAGE_DIR}/qrc"

  if [[ -n "$qrc_source" ]]; then
    if [[ ! -x "$qrc_source" ]] \
      || ! install -m 0755 "$qrc_source" "$QRC_STAGED_BINARY"; then
      warn "测试提供的 qrc 不可用；升级仍会继续，文字订阅链接不受影响。"
      cleanup_qrc_stage
      return 0
    fi
  else
    for qrc_source in curl sha256sum tar install; do
      if ! command -v "$qrc_source" >/dev/null 2>&1; then
        warn "缺少 ${qrc_source}，无法更新可选 qrc；文字订阅链接不受影响。"
        cleanup_qrc_stage
        return 0
      fi
    done
    qrc_asset="qrc_${QRC_VERSION}_linux_${ARCH}.tar.gz"
    qrc_archive="${QRC_STAGE_DIR}/qrc.tar.gz"
    if ! download_optional_verified "qrc ${QRC_VERSION}" \
        "https://github.com/fumiyas/qrc/releases/download/v${QRC_VERSION}/${qrc_asset}" \
        "$(sha_for_arch QRC)" "$qrc_archive"; then
      cleanup_qrc_stage
      return 0
    fi
    if ! tar --no-same-owner -xzf "$qrc_archive" \
        -C "$QRC_STAGE_DIR" qrc \
      || [[ ! -f "$QRC_STAGED_BINARY" ]] \
      || ! chmod 0755 "$QRC_STAGED_BINARY"; then
      warn "qrc 准备失败；升级仍会继续，文字订阅链接不受影响。"
      cleanup_qrc_stage
      return 0
    fi
  fi

  if ! qrc_help="$("$QRC_STAGED_BINARY" --help 2>&1)" \
    || ! grep -Fq -- '--output-format=<auto|ansi|sixel|unicode>' \
      <<< "$qrc_help"; then
    warn "qrc 运行检查失败；升级仍会继续，文字订阅链接不受影响。"
    cleanup_qrc_stage
    return 0
  fi
  ok "可选终端二维码组件 qrc ${QRC_VERSION} 已校验。"
}

install_staged_qrc() {
  local qrc_tmp=""
  [[ -n "$QRC_STAGED_BINARY" && -x "$QRC_STAGED_BINARY" ]] || return 0
  if ! qrc_tmp="$(mktemp "${NEKO_LIBEXEC}/.qrc.tmp.XXXXXX")" \
    || ! install -m 0755 "$QRC_STAGED_BINARY" "$qrc_tmp" \
    || ! mv -f -- "$qrc_tmp" "$NEKO_LIBEXEC/qrc"; then
    [[ -z "$qrc_tmp" ]] || rm -f -- "$qrc_tmp"
    warn "qrc 安装失败；已保留原状态，文字订阅链接不受影响。"
    return 0
  fi
  ok "终端二维码组件已更新。"
}
cleanup_nexttrace_stage() {
  local base="${NEKO_UPDATE_TMP_DIR%/}"
  [[ -n "$NEXTTRACE_STAGE_DIR" ]] || return 0
  if [[ -n "$base" \
    && "$NEXTTRACE_STAGE_DIR" == "$base"/neko-nexttrace-stage.* ]]; then
    rm -rf -- "$NEXTTRACE_STAGE_DIR"
    NEXTTRACE_STAGE_DIR=""
    NEXTTRACE_STAGED_BINARY=""
  fi
}

cleanup_core_stage() {
  local base="${NEKO_UPDATE_TMP_DIR%/}" temp
  for temp in "${CORE_ACTIVATION_TEMPS[@]:-}"; do
    [[ -n "$temp" && "$temp" == "$NEKO_LIBEXEC"/.*.next.* ]] \
      && rm -f -- "$temp"
  done
  CORE_ACTIVATION_TEMPS=()
  [[ -n "$CORE_STAGE_DIR" ]] || return 0
  if [[ -n "$base" && "$CORE_STAGE_DIR" == "$base"/neko-core-stage.* ]]; then
    rm -rf -- "$CORE_STAGE_DIR"
    CORE_STAGE_DIR=""
    CORE_STAGE_BIN_DIR=""
  fi
}


stage_optional_nexttrace() {
  local nexttrace_source="${NEKO_UPDATE_NEXTTRACE_BINARY:-}"
  local nexttrace_asset nexttrace_version

  case "${ARCH_OVERRIDE:-$(uname -m)}" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)
      warn "当前 CPU 没有匹配的 NextTrace；升级仍会继续，只跳过三网线路测试。"
      return 0
      ;;
  esac
  export ARCH

  if ! NEXTTRACE_STAGE_DIR="$(
      mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-nexttrace-stage.XXXXXX"
    )"; then
    NEXTTRACE_STAGE_DIR=""
    warn "无法创建 NextTrace 临时目录；升级仍会继续，只跳过三网线路测试。"
    return 0
  fi
  NEXTTRACE_STAGED_BINARY="${NEXTTRACE_STAGE_DIR}/nexttrace-tiny"

  if [[ -n "$nexttrace_source" ]]; then
    if [[ ! -x "$nexttrace_source" ]] \
      || ! install -m 0755 \
        "$nexttrace_source" "$NEXTTRACE_STAGED_BINARY"; then
      warn "测试提供的 NextTrace 不可用；升级仍会继续，只跳过三网线路测试。"
      cleanup_nexttrace_stage
      return 0
    fi
  else
    for nexttrace_source in curl sha256sum install; do
      if ! command -v "$nexttrace_source" >/dev/null 2>&1; then
        warn "缺少 ${nexttrace_source}，无法更新可选 NextTrace；只跳过三网线路测试。"
        cleanup_nexttrace_stage
        return 0
      fi
    done
    nexttrace_asset="nexttrace-tiny_linux_${ARCH}"
    if ! download_optional_verified "NextTrace Tiny ${NEXTTRACE_VERSION}" \
        "https://github.com/nxtrace/NTrace-core/releases/download/v${NEXTTRACE_VERSION}/${nexttrace_asset}" \
        "$(sha_for_arch NEXTTRACE)" "$NEXTTRACE_STAGED_BINARY"; then
      cleanup_nexttrace_stage
      return 0
    fi
    if ! chmod 0755 "$NEXTTRACE_STAGED_BINARY"; then
      warn "NextTrace 准备失败；升级仍会继续，只跳过三网线路测试。"
      cleanup_nexttrace_stage
      return 0
    fi
  fi

  nexttrace_version="$(
    NO_COLOR=1 "$NEXTTRACE_STAGED_BINARY" --version 2>&1 || true
  )"
  if ! grep -Fq "NextTrace v${NEXTTRACE_VERSION}" \
      <<< "$nexttrace_version"; then
    warn "NextTrace 运行检查失败；升级仍会继续，只跳过三网线路测试。"
    cleanup_nexttrace_stage
    return 0
  fi
  ok "可选三网线路组件 NextTrace Tiny ${NEXTTRACE_VERSION} 已校验。"
}

install_staged_nexttrace() {
  local nexttrace_tmp=""
  [[ -n "$NEXTTRACE_STAGED_BINARY" \
    && -x "$NEXTTRACE_STAGED_BINARY" ]] || return 0
  if ! nexttrace_tmp="$(
      mktemp "${NEKO_LIBEXEC}/.nexttrace-tiny.tmp.XXXXXX"
    )" \
    || ! install -m 0755 "$NEXTTRACE_STAGED_BINARY" "$nexttrace_tmp" \
    || ! mv -f -- "$nexttrace_tmp" "$NEKO_LIBEXEC/nexttrace-tiny"; then
    [[ -z "$nexttrace_tmp" ]] || rm -f -- "$nexttrace_tmp"
    warn "NextTrace 安装失败；已保留原状态，只跳过三网线路测试。"
    return 0
  fi
  ok "三网线路检测组件已更新。"
}


restore_tree() {
  local backup="$1" target="$2"
  [[ -e "$backup" ]] || return 0
  rm -rf -- "$target"
  cp -a -- "$backup" "$target"
}

restore_optional_tree() {
  local backup="$1" target="$2"
  if [[ -e "$backup" ]]; then
    restore_tree "$backup" "$target"
  else
    rm -rf -- "$target"
  fi
}

restore_optional_file() {
  local backup="$1" target="$2"
  if [[ -e "$backup" ]]; then
    cp -a -- "$backup" "$target"
  else
    rm -f -- "$target"
  fi
}

rollback_upgrade() {
  local rc="$1" rollback_ok=1
  set +e
  warn "升级未完成，正在恢复升级前的状态、证书和配置……"
  restore_tree "$BACKUP_DIR/etc" "$NEKO_ETC" || rollback_ok=0
  restore_tree "$BACKUP_DIR/lego" "$NEKO_VAR/lego" || rollback_ok=0
  restore_tree "$BACKUP_DIR/lib" "$NEKO_LIBEXEC/lib" || rollback_ok=0
  restore_optional_tree \
    "$BACKUP_DIR/panel" "$NEKO_LIBEXEC/panel" || rollback_ok=0
  cp -a -- "$BACKUP_DIR/versions.env" "$NEKO_LIBEXEC/versions.env" || rollback_ok=0
  restore_core_binaries || rollback_ok=0
  cp -a -- "$BACKUP_DIR/panel.sh" "$NEKO_LIBEXEC/panel.sh" || rollback_ok=0
  cp -a -- "$BACKUP_DIR/renew.sh" "$NEKO_LIBEXEC/renew.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/diagnostics.sh" "$NEKO_LIBEXEC/diagnostics.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/route-diagnostics.sh" \
    "$NEKO_LIBEXEC/route-diagnostics.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/akdns.sh" "$NEKO_LIBEXEC/akdns.sh" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/qrc" "$NEKO_LIBEXEC/qrc" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/nexttrace-tiny" \
    "$NEKO_LIBEXEC/nexttrace-tiny" || rollback_ok=0
  restore_optional_file \
    "$BACKUP_DIR/neko-hysteria.service" \
    "$NEKO_SYSTEMD/neko-hysteria.service" || rollback_ok=0
  case "$UPGRADE_FIREWALL_MANAGER" in
    firewalld)
      restore_optional_file \
        "$BACKUP_DIR/neko-proxy-firewalld.xml" \
        "$FIREWALLD_SERVICE_FILE" || rollback_ok=0
      firewall-cmd --reload >/dev/null 2>&1 || rollback_ok=0
      ;;
    ufw)
      restore_optional_file \
        "$BACKUP_DIR/neko-proxy-ufw" \
        "$UFW_PROFILE_FILE" || rollback_ok=0
      ufw app update NekoProxy >/dev/null 2>&1 || rollback_ok=0
      ;;
    none)
      ;;
    *)
      rollback_ok=0
      ;;
  esac
  systemctl daemon-reload >/dev/null 2>&1 || rollback_ok=0
  restore_upgrade_service_states || rollback_ok=0
  if (( rollback_ok == 1 )); then
    cleanup_qrc_stage
    cleanup_nexttrace_stage
    cleanup_core_stage
    cleanup_backup
  else
    cleanup_qrc_stage
    cleanup_nexttrace_stage
    cleanup_core_stage
    warn "自动恢复未完全成功；为防止数据丢失，备份保留在 ${BACKUP_DIR}。"
    warn "请停止 Neko 服务且不要再次升级；核对后从该目录恢复 etc、lego、lib、core、versions.env 和单元文件，再按 services.state 恢复服务启停状态。"
  fi
  exit "$rc"
}

finish_upgrade() {
  local rc=$?
  trap - EXIT ERR INT TERM
  if (( rc != 0 && ROLLBACK_READY == 1 )); then
    rollback_upgrade "$rc"
  fi
  cleanup_qrc_stage
  cleanup_nexttrace_stage
  cleanup_core_stage
  cleanup_backup
  exit "$rc"
}

trap finish_upgrade EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_installed_configs() {
  runtime_validate_core_configs \
    --libexec-dir "$NEKO_LIBEXEC" \
    --config-dir "$NEKO_ETC/config" \
    --subscription-dir "$NEKO_ETC/subscriptions" \
    --network-mode "$NETWORK_MODE" --output stdout-quiet
}

certificate_has_strict_domains() {
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || return 1
  certificate_has_active_domains "$CERT_FILE"
}

set_certificate_permissions() {
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" == "1" ]]; then
    runtime_set_lego_permissions \
      --lego-dir "$NEKO_VAR/lego" --service-user "$NEKO_USER" \
      --ownership preserve --path-policy trusted
    return
  fi
  runtime_set_lego_permissions \
    --lego-dir "$NEKO_VAR/lego" --service-user "$NEKO_USER" \
    --ownership managed --path-policy trusted
}

resolve_strict_endpoints() {
  derive_subscription_domains "$DOMAIN"
  if [[ -n "${NEKO_UPDATE_IPV4_OVERRIDE:-}" || -n "${NEKO_UPDATE_IPV6_OVERRIDE:-}" ]]; then
    if network_mode_has_ipv4; then
      [[ -n "${NEKO_UPDATE_IPV4_OVERRIDE:-}" ]] \
        || die "当前模式的 IPv4 测试覆盖缺失。"
      is_ipv4_literal "$NEKO_UPDATE_IPV4_OVERRIDE" || die "IPv4 测试覆盖无效。"
      SUBSCRIPTION_IPV4_ADDRESS="$NEKO_UPDATE_IPV4_OVERRIDE"
    else
      SUBSCRIPTION_IPV4_ADDRESS=""
    fi
    if network_mode_has_ipv6; then
      [[ -n "${NEKO_UPDATE_IPV6_OVERRIDE:-}" ]] \
        || die "当前模式的 IPv6 测试覆盖缺失。"
      is_ipv6_literal "$NEKO_UPDATE_IPV6_OVERRIDE" || die "IPv6 测试覆盖无效。"
      SUBSCRIPTION_IPV6_ADDRESS="$NEKO_UPDATE_IPV6_OVERRIDE"
    else
      SUBSCRIPTION_IPV6_ADDRESS=""
    fi
  else
    ensure_dns_query_tool
    check_strict_stack_dns "$DOMAIN" "$NETWORK_MODE"
  fi
}

installed_manifest_value() {
  local file="$1" key="$2" value
  value="$(sed -n "s/^${key}=\"\([^\"]*\)\"$/\\1/p" "$file")"
  [[ -n "$value" && "$value" != *$'\n'* \
    && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1
  printf '%s' "$value"
}

core_version_output_matches() {
  local component="$1" version="$2" output="$3" first_line
  first_line="${output%%$'\n'*}"
  case "$component" in
    xray)
      [[ "$first_line" == "Xray ${version} "* ]]
      ;;
    sing-box)
      [[ "$first_line" == "sing-box version ${version}" ]]
      ;;
    hysteria)
      awk -v expected="v${version}" '
        $1 == "Version:" && $2 == expected { found = 1 }
        END { exit(found ? 0 : 1) }
      ' <<< "$output"
      ;;
    caddy)
      [[ "$first_line" == "v${version}" \
        || "$first_line" == "v${version} "* ]]
      ;;
    lego)
      [[ "$first_line" == "lego version ${version} "* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

core_spec_rows() {
  printf '%s\n' \
    'XRAY|xray|Xray' \
    'SING_BOX|sing-box|sing-box' \
    'HYSTERIA|hysteria|Hysteria' \
    'CADDY|caddy|Caddy' \
    'LEGO|lego|lego'
}

upgrade_test_failpoint() {
  local point="$1"
  [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 ]] || return 0
  case ",${NEKO_UPDATE_TEST_FAIL_POINTS:-}," in
    *",${point},"*)
      warn "测试故障注入：${point}"
      return 1
      ;;
  esac
  return 0
}

upgrade_test_event() {
  [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 \
    && -n "${NEKO_UPDATE_TEST_EVENT_LOG:-}" ]] || return 0
  printf '%s\n' "$1" >> "$NEKO_UPDATE_TEST_EVENT_LOG"
}

upgrade_test_signal_point() {
  local point="$1"
  [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 ]] || return 0
  case ",${NEKO_UPDATE_TEST_FAIL_POINTS:-}," in
    *",signal-int-${point},"*)
      warn "测试信号注入：signal-int-${point}"
      kill -INT "$$"
      return 1
      ;;
    *",signal-term-${point},"*)
      warn "测试信号注入：signal-term-${point}"
      kill -TERM "$$"
      return 1
      ;;
  esac
  return 0
}

core_binary_version_output() {
  local binary="$1" path="$2"
  case "$binary" in
    xray|sing-box|hysteria|caddy) "$path" version 2>&1 ;;
    lego) "$path" --version 2>&1 ;;
    *) return 64 ;;
  esac
}

prepare_core_upgrade_contract() {
  local prefix binary label version_key hash_key
  local installed_version installed_hash target_version target_hash
  local version_output installed_manifest="$NEKO_LIBEXEC/versions.env"

  case "${ARCH_OVERRIDE:-$(uname -m)}" in
    x86_64|amd64) CORE_ARCH=amd64; CORE_ARCH_KEY=AMD64 ;;
    aarch64|arm64) CORE_ARCH=arm64; CORE_ARCH_KEY=ARM64 ;;
    *) die "当前 CPU 没有可验证的 Neko 核心清单；未开始升级。" ;;
  esac
  CORE_TARGET_MANIFEST="$SCRIPT_DIR/versions.env"
  if [[ -n "${NEKO_UPDATE_TARGET_VERSIONS_FILE:-}" ]]; then
    [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 ]] \
      || die "生产升级不接受外部目标版本清单。"
    CORE_TARGET_MANIFEST="$NEKO_UPDATE_TARGET_VERSIONS_FILE"
  fi
  [[ -f "$CORE_TARGET_MANIFEST" && ! -L "$CORE_TARGET_MANIFEST" ]] \
    || die "目标核心版本清单缺失或类型异常；未开始升级。"

  CORE_UPGRADE_REQUIRED=0
  while IFS='|' read -r prefix binary label; do
    version_key="${prefix}_VERSION"
    hash_key="${prefix}_${CORE_ARCH_KEY}_SHA256"
    installed_version="$(
      installed_manifest_value "$installed_manifest" "$version_key"
    )" || die "已安装版本清单缺少有效的 ${version_key}；未开始升级。"
    installed_hash="$(
      installed_manifest_value "$installed_manifest" "$hash_key"
    )" || die "已安装版本清单缺少有效的 ${hash_key}；未开始升级。"
    target_version="$(
      installed_manifest_value "$CORE_TARGET_MANIFEST" "$version_key"
    )" || die "目标版本清单缺少有效的 ${version_key}；未开始升级。"
    target_hash="$(
      installed_manifest_value "$CORE_TARGET_MANIFEST" "$hash_key"
    )" || die "目标版本清单缺少有效的 ${hash_key}；未开始升级。"
    [[ "$installed_hash" =~ ^[0-9a-f]{64}$ ]] \
      || die "已安装 ${label} 校验值格式无效；未开始升级。"
    [[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] \
      || die "目标 ${label} 缺少固定 SHA-256；未开始升级。"
    [[ -x "$NEKO_LIBEXEC/$binary" ]] \
      || die "已安装 ${label} 核心不可执行；未开始升级。"
    version_output="$(
      core_binary_version_output "$binary" "$NEKO_LIBEXEC/$binary"
    )" || die "无法读取已安装 ${label} 的版本身份；未开始升级。"
    core_version_output_matches "$binary" "$installed_version" "$version_output" \
      || die "已安装 ${label} 无法确认版本 ${installed_version}；未开始升级。"
    if [[ "$installed_version" != "$target_version" \
      || "$installed_hash" != "$target_hash" ]]; then
      CORE_UPGRADE_REQUIRED=1
    fi
  done < <(core_spec_rows)
}

stage_core_release_artifact() {
  local label="$1" url="$2" expected="$3" fixture_name="$4" output="$5"
  local source_dir="${NEKO_UPDATE_CORE_ARCHIVE_DIR:-}"
  upgrade_test_failpoint "download-${fixture_name}" || return
  if [[ -n "$source_dir" ]]; then
    [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 ]] \
      || die "生产升级不接受本地核心归档目录。"
    [[ -f "$source_dir/$fixture_name" \
      && ! -L "$source_dir/$fixture_name" ]] \
      || { warn "测试核心归档缺失：${fixture_name}"; return 1; }
    upgrade_test_failpoint "copy-${fixture_name}" || return
    install -m 0600 -- "$source_dir/$fixture_name" "$output" || return
    printf '%s  %s\n' "$expected" "$output" \
      | sha256sum --check --status || {
        warn "${label} 的 SHA-256 校验失败。"
        return 1
      }
  else
    download_verified "$label" "$url" "$expected" "$output"
  fi
}

stage_core_upgrade_set() {
  local prefix binary label version_key hash_key version hash output
  local xray_asset sing_asset hysteria_asset caddy_asset lego_asset
  (( CORE_UPGRADE_REQUIRED == 1 )) || return 0
  CORE_STAGE_DIR="$(
    mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-core-stage.XXXXXX"
  )" || die "无法创建核心升级暂存目录。"
  chmod 0700 "$CORE_STAGE_DIR"
  CORE_STAGE_BIN_DIR="$CORE_STAGE_DIR/bin"
  install -d -m 0700 \
    "$CORE_STAGE_DIR/downloads" "$CORE_STAGE_DIR/unpack" \
    "$CORE_STAGE_BIN_DIR"

  if [[ "$CORE_ARCH" == amd64 ]]; then
    xray_asset=Xray-linux-64.zip
  else
    xray_asset=Xray-linux-arm64-v8a.zip
  fi
  version="$(installed_manifest_value "$CORE_TARGET_MANIFEST" XRAY_VERSION)"
  hash="$(
    installed_manifest_value \
      "$CORE_TARGET_MANIFEST" "XRAY_${CORE_ARCH_KEY}_SHA256"
  )"
  stage_core_release_artifact "Xray ${version}" \
    "https://github.com/XTLS/Xray-core/releases/download/v${version}/${xray_asset}" \
    "$hash" xray.zip "$CORE_STAGE_DIR/downloads/xray.zip" \
    || die "Xray 核心暂存失败。"

  version="$(installed_manifest_value "$CORE_TARGET_MANIFEST" SING_BOX_VERSION)"
  hash="$(
    installed_manifest_value \
      "$CORE_TARGET_MANIFEST" "SING_BOX_${CORE_ARCH_KEY}_SHA256"
  )"
  sing_asset="sing-box-${version}-linux-${CORE_ARCH}.tar.gz"
  stage_core_release_artifact "sing-box ${version}" \
    "https://github.com/SagerNet/sing-box/releases/download/v${version}/${sing_asset}" \
    "$hash" sing-box.tar.gz "$CORE_STAGE_DIR/downloads/sing-box.tar.gz" \
    || die "sing-box 核心暂存失败。"

  version="$(installed_manifest_value "$CORE_TARGET_MANIFEST" HYSTERIA_VERSION)"
  hash="$(
    installed_manifest_value \
      "$CORE_TARGET_MANIFEST" "HYSTERIA_${CORE_ARCH_KEY}_SHA256"
  )"
  hysteria_asset="hysteria-linux-${CORE_ARCH}"
  stage_core_release_artifact "Hysteria ${version}" \
    "https://github.com/apernet/hysteria/releases/download/app%2Fv${version}/${hysteria_asset}" \
    "$hash" hysteria "$CORE_STAGE_DIR/downloads/hysteria" \
    || die "Hysteria 核心暂存失败。"

  version="$(installed_manifest_value "$CORE_TARGET_MANIFEST" CADDY_VERSION)"
  hash="$(
    installed_manifest_value \
      "$CORE_TARGET_MANIFEST" "CADDY_${CORE_ARCH_KEY}_SHA256"
  )"
  caddy_asset="caddy_${version}_linux_${CORE_ARCH}.tar.gz"
  stage_core_release_artifact "Caddy ${version}" \
    "https://github.com/caddyserver/caddy/releases/download/v${version}/${caddy_asset}" \
    "$hash" caddy.tar.gz "$CORE_STAGE_DIR/downloads/caddy.tar.gz" \
    || die "Caddy 核心暂存失败。"

  version="$(installed_manifest_value "$CORE_TARGET_MANIFEST" LEGO_VERSION)"
  hash="$(
    installed_manifest_value \
      "$CORE_TARGET_MANIFEST" "LEGO_${CORE_ARCH_KEY}_SHA256"
  )"
  lego_asset="lego_v${version}_linux_${CORE_ARCH}.tar.gz"
  stage_core_release_artifact "lego ${version}" \
    "https://github.com/go-acme/lego/releases/download/v${version}/${lego_asset}" \
    "$hash" lego.tar.gz "$CORE_STAGE_DIR/downloads/lego.tar.gz" \
    || die "lego 核心暂存失败。"

  install -d -m 0700 \
    "$CORE_STAGE_DIR/unpack/xray" "$CORE_STAGE_DIR/unpack/caddy" \
    "$CORE_STAGE_DIR/unpack/lego"
  unzip -q "$CORE_STAGE_DIR/downloads/xray.zip" \
    -d "$CORE_STAGE_DIR/unpack/xray" \
    || die "Xray 核心解压失败。"
  version="$(installed_manifest_value "$CORE_TARGET_MANIFEST" SING_BOX_VERSION)"
  tar --no-same-owner -xzf "$CORE_STAGE_DIR/downloads/sing-box.tar.gz" \
    -C "$CORE_STAGE_DIR/unpack" || die "sing-box 核心解压失败。"
  tar --no-same-owner -xzf "$CORE_STAGE_DIR/downloads/caddy.tar.gz" \
    -C "$CORE_STAGE_DIR/unpack/caddy" || die "Caddy 核心解压失败。"
  tar --no-same-owner -xzf "$CORE_STAGE_DIR/downloads/lego.tar.gz" \
    -C "$CORE_STAGE_DIR/unpack/lego" || die "lego 核心解压失败。"
  install -m 0755 "$CORE_STAGE_DIR/unpack/xray/xray" \
    "$CORE_STAGE_BIN_DIR/xray"
  install -m 0755 \
    "$CORE_STAGE_DIR/unpack/sing-box-${version}-linux-${CORE_ARCH}/sing-box" \
    "$CORE_STAGE_BIN_DIR/sing-box"
  install -m 0755 "$CORE_STAGE_DIR/downloads/hysteria" \
    "$CORE_STAGE_BIN_DIR/hysteria"
  install -m 0755 "$CORE_STAGE_DIR/unpack/caddy/caddy" \
    "$CORE_STAGE_BIN_DIR/caddy"
  install -m 0755 "$CORE_STAGE_DIR/unpack/lego/lego" \
    "$CORE_STAGE_BIN_DIR/lego"

  while IFS='|' read -r prefix binary label; do
    version_key="${prefix}_VERSION"
    version="$(
      installed_manifest_value "$CORE_TARGET_MANIFEST" "$version_key"
    )"
    output="$(
      core_binary_version_output "$binary" "$CORE_STAGE_BIN_DIR/$binary"
    )" || die "暂存 ${label} 无法执行无副作用版本检查。"
    core_version_output_matches "$binary" "$version" "$output" \
      || die "暂存 ${label} 无法确认目标版本 ${version}。"
  done < <(core_spec_rows)
  upgrade_test_event core-stage-validated
  upgrade_test_signal_point after-core-staging
  ok "五个目标核心已完成固定校验值和版本身份验证。"
}

target_core_binary() {
  local binary="$1"
  if (( CORE_UPGRADE_REQUIRED == 1 )); then
    printf '%s' "$CORE_STAGE_BIN_DIR/$binary"
  else
    printf '%s' "$NEKO_LIBEXEC/$binary"
  fi
}

set_upgrade_root_owner() {
  local path="$1"
  if (( EUID == 0 )); then
    chown root:root "$path"
  else
    [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 ]]
  fi
}

snapshot_core_binaries() {
  local prefix binary label
  install -d -m 0700 "$BACKUP_DIR/core"
  while IFS='|' read -r prefix binary label; do
    cp -a -- "$NEKO_LIBEXEC/$binary" "$BACKUP_DIR/core/$binary" \
      || die "无法快照已安装 ${label} 核心。"
  done < <(core_spec_rows)
}

snapshot_upgrade_service_states() {
  local service state state_rc
  : > "$BACKUP_DIR/services.state"
  chmod 0600 "$BACKUP_DIR/services.state"
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    if systemctl is-active --quiet "${service}.service"; then
      state=active
    else
      state_rc=$?
      (( state_rc == 3 )) \
        || die "无法快照 ${service} 的升级前运行状态。"
      state=inactive
    fi
    printf '%s %s\n' "$service" "$state" >> "$BACKUP_DIR/services.state"
  done
}

restore_core_binaries() {
  local prefix binary label tmp restore_ok=1
  while IFS='|' read -r prefix binary label; do
    if ! upgrade_test_failpoint "rollback-file-${binary}"; then
      restore_ok=0
      continue
    fi
    if ! tmp="$(mktemp "${NEKO_LIBEXEC}/.${binary}.rollback.XXXXXX")"; then
      restore_ok=0
      continue
    fi
    rm -f -- "$tmp"
    if ! cp -a -- "$BACKUP_DIR/core/$binary" "$tmp" \
      || ! mv -f -- "$tmp" "$NEKO_LIBEXEC/$binary"; then
      rm -f -- "$tmp"
      restore_ok=0
    fi
  done < <(core_spec_rows)
  (( restore_ok == 1 ))
}

restore_upgrade_service_states() {
  local service state state_rc restore_ok=1
  [[ -r "$BACKUP_DIR/services.state" ]] || return 1
  while read -r service state; do
    case "$state" in
      active)
        upgrade_test_failpoint "rollback-service-${service}" \
          || { restore_ok=0; continue; }
        systemctl restart "${service}.service" >/dev/null 2>&1 \
          && systemctl is-active --quiet "${service}.service" \
          || restore_ok=0
        ;;
      inactive)
        if ! systemctl stop "${service}.service" >/dev/null 2>&1; then
          restore_ok=0
        elif systemctl is-active --quiet "${service}.service"; then
          restore_ok=0
        else
          state_rc=$?
          (( state_rc == 3 )) || restore_ok=0
        fi
        ;;
      *) restore_ok=0 ;;
    esac
  done < "$BACKUP_DIR/services.state"
  (( restore_ok == 1 ))
}

validate_configs_with_core_dir() {
  local core_dir="$1" family check_log check_rc timeout_binary
  runtime_validate_core_configs \
    --libexec-dir "$core_dir" \
    --config-dir "$NEKO_ETC/config" \
    --subscription-dir "$NEKO_ETC/subscriptions" \
    --network-mode "$NETWORK_MODE" --output stdout-quiet || return

  timeout_binary="$(command -v timeout)" || return
  for family in v4 v6 v4-to-v6 v6-to-v4; do
    [[ -s "$NEKO_ETC/config/hysteria-${family}.yaml" ]] || continue
    check_log="$(mktemp "$BACKUP_DIR/hysteria-check.XXXXXX")" || return
    check_rc=0
    PATH=/nonexistent "$timeout_binary" --signal=TERM --kill-after=1s 2s \
      "$core_dir/hysteria" server --disable-update-check \
      --config "$NEKO_ETC/config/hysteria-${family}.yaml" \
      >"$check_log" 2>&1 || check_rc=$?
    if (( check_rc == 124 )) \
      || grep -Fq 'executable file not found' "$check_log" \
      || { grep -Fq 'invalid config: listen: listen udp' "$check_log" \
        && grep -Fq 'bind: address already in use' "$check_log"; } \
      || { [[ "${NEKO_UPDATE_TEST_MODE:-0}" == 1 ]] \
        && grep -Fq 'invalid config: listen: listen udp' "$check_log" \
        && grep -Fq 'bind: cannot assign requested address' "$check_log"; }; then
      rm -f -- "$check_log"
      continue
    else
      warn "Hysteria ${family} 暂存配置校验失败（退出码 ${check_rc}）："
      sed -n '1,40p' "$check_log" >&2
      rm -f -- "$check_log"
      return 1
    fi
  done
}

activate_staged_core_set() {
  local prefix binary label temp
  (( CORE_UPGRADE_REQUIRED == 1 )) || return 0
  CORE_ACTIVATION_TEMPS=()
  while IFS='|' read -r prefix binary label; do
    temp="$(mktemp "${NEKO_LIBEXEC}/.${binary}.next.XXXXXX")" || return
    if ! upgrade_test_failpoint "activation-copy-${binary}" \
      || ! install -m 0700 "$CORE_STAGE_BIN_DIR/$binary" "$temp"; then
      rm -f -- "$temp"
      return 1
    fi
    if ! set_upgrade_root_owner "$temp"; then
      rm -f -- "$temp"
      return 1
    fi
    CORE_ACTIVATION_TEMPS+=("$temp")
  done < <(core_spec_rows)

  while IFS='|' read -r prefix binary label; do
    upgrade_test_failpoint "activate-${binary}" || return
    temp=""
    for temp in "${CORE_ACTIVATION_TEMPS[@]}"; do
      [[ "$temp" == "$NEKO_LIBEXEC/.${binary}.next."* ]] || continue
      chmod 0755 "$temp" || return
      mv -f -- "$temp" "$NEKO_LIBEXEC/$binary" || return
      upgrade_test_event "activate-${binary}"
      break
    done
    [[ -n "$temp" ]] || return 1
  done < <(core_spec_rows)
  CORE_ACTIVATION_TEMPS=()
  upgrade_test_signal_point after-core-activation
  ok "五个目标核心已在明确提交点完成整组激活。"
}

restart_and_verify_upgrade_services() {
  local service
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    upgrade_test_failpoint "service-${service}" || return
    systemctl restart "${service}.service" || return
    systemctl is-active --quiet "${service}.service" || return
    upgrade_test_event "service-${service}"
  done
}

commit_target_versions_manifest() {
  local tmp
  tmp="$(mktemp "${NEKO_LIBEXEC}/.versions.env.next.XXXXXX")" || return
  if ! install -m 0644 "$CORE_TARGET_MANIFEST" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! set_upgrade_root_owner "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! upgrade_test_failpoint manifest-commit \
    || ! mv -f -- "$tmp" "$NEKO_LIBEXEC/versions.env"; then
    rm -f -- "$tmp"
    return 1
  fi
  upgrade_test_event manifest-committed
}

verify_committed_core_set() {
  local prefix binary label version output
  while IFS='|' read -r prefix binary label; do
    version="$(
      installed_manifest_value \
        "$NEKO_LIBEXEC/versions.env" "${prefix}_VERSION"
    )" || return
    output="$(core_binary_version_output "$binary" "$NEKO_LIBEXEC/$binary")" \
      || return
    core_version_output_matches "$binary" "$version" "$output" || return
  done < <(core_spec_rows)
}

main() {
  local current_schema current_release certificate_domain service source_file
  local library_file panel_module
  local reality_key_binary target_validation_dir
  local trojan_port trojan_password hy2_start hy2_end port
  local tuic_port ss_port anytls_port vision_port xhttp_port
  local cross_hy2_start="null" cross_hy2_end="null"
  local cross_tuic_port="null" cross_ss_port="null" cross_anytls_port="null"
  local cross_trojan_port="null" cross_vision_port="null" cross_xhttp_port="null"
  local anyreality_enabled anyreality_port="" cross_anyreality_port="null"
  local anyreality_password="" anyreality_private="" anyreality_public=""
  local anyreality_short_id="" anyreality_pair=""
  local cross_ipv4_to_ipv6_token="" cross_ipv6_to_ipv4_token=""
  local -a domain_args=()

  if (( EUID != 0 )) && [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    die "请使用 root 运行升级脚本。"
  fi
  require_commands \
    flock jq openssl find cp systemctl stat env ip awk sed timeout ss \
    curl sha256sum tar unzip install mktemp mv chmod chown

  # Serialize before reading mutable state.  Panel address-family operations,
  # token rotation and certificate renewal use the same lock.
  mkdir -p -- "$(dirname -- "$NEKO_UPDATE_LOCK_FILE")"
  exec 9>"$NEKO_UPDATE_LOCK_FILE"
  flock -n 9 || die "另一个 Neko 维护任务正在运行。"

  [[ -r "$NEKO_STATE" ]] || die "没有找到已安装的 Neko：${NEKO_STATE}"
  [[ -d "$NEKO_ETC/config" && -d "$NEKO_ETC/subscriptions" ]] \
    || die "现有 Neko 配置或订阅目录不完整。"
  [[ -d "$NEKO_VAR/lego" ]] || die "现有 Neko 证书目录不完整。"
  [[ -r "$NEKO_LIBEXEC/lib/common.sh" && -r "$NEKO_LIBEXEC/lib/render.sh" \
    && -r "$NEKO_LIBEXEC/lib/firewall.sh" && -r "$NEKO_LIBEXEC/versions.env" \
    && -r "$NEKO_LIBEXEC/panel.sh" && -r "$NEKO_LIBEXEC/renew.sh" ]] \
    || die "现有 Neko 程序文件不完整。"
  if grep -Fq '/state.sh"' "$NEKO_LIBEXEC/lib/common.sh"; then
    [[ -r "$NEKO_LIBEXEC/lib/state.sh" ]] \
      || die "现有 Neko 状态库不完整。"
  fi
  for service in sing-box xray hysteria caddy lego; do
    [[ -x "$NEKO_LIBEXEC/$service" ]] || die "现有核心缺失：${service}"
  done
  [[ -r "$SCRIPT_DIR/lib/common.sh" && -r "$SCRIPT_DIR/lib/state.sh" \
    && -r "$SCRIPT_DIR/lib/render.sh" \
    && -r "$SCRIPT_DIR/lib/firewall.sh" \
    && -r "$SCRIPT_DIR/lib/transaction.sh" \
    && -r "$SCRIPT_DIR/runtime/panel.sh" \
    && -r "$SCRIPT_DIR/runtime/route-diagnostics.sh" \
    && -r "$SCRIPT_DIR/runtime/renew.sh" \
    && -r "$SCRIPT_DIR/runtime/hysteria-dual.sh" \
    && -r "$SCRIPT_DIR/runtime/akdns.sh" \
    && -r "$SCRIPT_DIR/systemd/neko-hysteria.service" ]] || die "升级包不完整。"
  for source_file in \
    lib/common-platform.sh lib/common-network.sh lib/common-acme.sh \
    lib/common-credentials.sh lib/common-download.sh lib/common-subscription.sh \
    lib/render-server.sh lib/render-caddy.sh lib/render-client.sh \
    lib/render-route-model.sh lib/render-subscriptions.sh \
    runtime/panel/system.sh runtime/panel/access.sh runtime/panel/family.sh \
    runtime/panel/third-party.sh runtime/panel/akdns-menu.sh \
    runtime/panel/route-guide.sh runtime/panel/ui.sh; do
    [[ -r "$SCRIPT_DIR/$source_file" ]] || die "升级包缺少 ${source_file}。"
  done
  if [[ -e "$NEKO_LIBEXEC/panel" ]] \
    && { [[ ! -d "$NEKO_LIBEXEC/panel" ]] \
      || [[ -L "$NEKO_LIBEXEC/panel" ]]; }; then
    die "现有面板模块目录类型异常；未开始升级。"
  fi
  # Confirm the installed set against its own committed manifest before any
  # download or mutation. A different target is then handled as one complete
  # five-core transaction rather than rejected or upgraded piecemeal.
  prepare_core_upgrade_contract
  validate_state_source_contract "$NEKO_STATE" 1 "$NEKO_STATE_SCHEMA" \
    || die "现有 state.json 不符合可升级状态契约；未开始升级。"
  current_schema="$(jq -er '
    (if .schema == null then 1 else .schema end)
    | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 缺少有效 schema。"
  current_release="$(jq -r '.release // "unknown"' "$NEKO_STATE")"
  [[ -d "$NEKO_SYSTEMD" && -w "$NEKO_SYSTEMD" ]] \
    || die "systemd 单元目录不可写：${NEKO_SYSTEMD}"
  [[ -d "$NEKO_UPDATE_TMP_DIR" && -w "$NEKO_UPDATE_TMP_DIR" ]] \
    || die "升级临时目录不可写：${NEKO_UPDATE_TMP_DIR}"
  stage_optional_qrc
  stage_optional_nexttrace

  (( current_schema == 1 || current_schema == 2 \
    || current_schema == 3 || current_schema == 4 )) \
    || die "不支持从 state schema ${current_schema} 升级。"
  DOMAIN="$(jq -er '.domain | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die "state.json 缺少域名。"
  ACME_EMAIL="$(jq -er '.acme_email | select(type == "string" and length > 0)' "$NEKO_STATE")" \
    || die "state.json 缺少 ACME 邮箱。"
  validate_domain "$DOMAIN" || die "state.json 中的域名无效。"
  validate_email "$ACME_EMAIL" || die "state.json 中的 ACME 邮箱无效。"
  ACME_METHOD="$(jq -r '.acme.method // "http-01"' "$NEKO_STATE")"
  ACME_METHOD="$(normalize_acme_method "$ACME_METHOD")" \
    || die "state.json 中的 ACME 验证方式无效。"
  if (( current_schema >= 3 )); then
    NETWORK_MODE="$(jq -r '.network.mode // empty' "$NEKO_STATE")"
    NETWORK_MODE="$(normalize_network_mode "$NETWORK_MODE")" \
      || die "state.json 中的网络安装模式无效。"
  else
    NETWORK_MODE="$NETWORK_MODE_DUAL"
  fi
  if [[ "$ACME_METHOD" == "$ACME_METHOD_CLOUDFLARE" ]]; then
    assert_cloudflare_dns_token_file
  fi
  hy2_start="$(jq -er '.ports.hysteria2_start | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 Hysteria2 起始端口无效。"
  hy2_end="$(jq -er '.ports.hysteria2_end | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 Hysteria2 结束端口无效。"
  tuic_port="$(jq -er '.ports.tuic | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 TUIC 端口无效。"
  ss_port="$(jq -er '.ports.ss2022 | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 SS2022 端口无效。"
  anytls_port="$(jq -er '.ports.anytls | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 AnyTLS 端口无效。"
  vision_port="$(jq -er '.ports.vless_reality_vision | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 VLESS Vision 端口无效。"
  xhttp_port="$(jq -er '.ports.vless_reality_xhttp | select(type == "number" and . == floor)' "$NEKO_STATE")" \
    || die "state.json 中的 VLESS XHTTP 端口无效。"
  (( hy2_start >= 10000 && hy2_end <= 60000 && hy2_end - hy2_start == 127 )) \
    || die "state.json 中的 Hysteria2 端口范围无效。"
  for port in "$tuic_port" "$ss_port" "$anytls_port" "$vision_port" "$xhttp_port"; do
    (( port >= 10000 && port <= 60000 )) \
      || die "state.json 中存在范围无效的代理端口。"
  done

  trojan_port="$(jq -r '.ports.trojan // empty' "$NEKO_STATE")"
  if [[ -n "$trojan_port" ]]; then
    [[ "$trojan_port" =~ ^[0-9]+$ ]] \
      || die "state.json 中的 Trojan 端口格式无效。"
    (( trojan_port >= 10000 && trojan_port <= 60000 )) \
      || die "state.json 中的 Trojan 端口范围无效。"
  fi

  anyreality_enabled="$(jq -r '.experimental.anyreality.enabled // false' "$NEKO_STATE")"
  case "$anyreality_enabled" in
    true)
      anyreality_port="$(jq -er '.experimental.anyreality.port | select(type == "number" and . == floor)' "$NEKO_STATE")" \
        || die "state.json 中的 AnyReality 端口无效。"
      anyreality_password="$(jq -r '.experimental.anyreality.password // empty' "$NEKO_STATE")"
      anyreality_private="$(jq -r '.experimental.anyreality.private_key // empty' "$NEKO_STATE")"
      anyreality_public="$(jq -r '.experimental.anyreality.public_key // empty' "$NEKO_STATE")"
      anyreality_short_id="$(jq -r '.experimental.anyreality.short_id // empty' "$NEKO_STATE")"
      (( anyreality_port >= 10000 && anyreality_port <= 60000 )) \
        || die "state.json 中的 AnyReality 端口范围无效。"
      [[ "$anyreality_password" =~ ^[A-Za-z0-9_-]{16,128}$ \
        && "$anyreality_private" =~ ^[A-Za-z0-9_-]{43}$ \
        && "$anyreality_public" =~ ^[A-Za-z0-9_-]{43}$ \
        && "$anyreality_short_id" =~ ^[0-9a-f]{16}$ ]] \
        || die "state.json 中的 AnyReality 凭据无效。"
      if network_mode_has_cross_routes && (( current_schema == 4 )); then
        cross_anyreality_port="$(jq -er '.experimental.anyreality.cross_port | select(type == "number" and . == floor)' "$NEKO_STATE")" \
          || die "state.json 中的跨族 AnyReality 端口无效。"
        (( cross_anyreality_port >= 10000 && cross_anyreality_port <= 60000 )) \
          || die "state.json 中的跨族 AnyReality 端口范围无效。"
      fi
      ;;
    false) ;;
    *) die "state.json 中的 AnyReality 启用状态无效。" ;;
  esac

  if network_mode_has_cross_routes && (( current_schema == 4 )); then
    cross_hy2_start="$(jq -er '.ports.cross.hysteria2_start | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 Hysteria2 起始端口无效。"
    cross_hy2_end="$(jq -er '.ports.cross.hysteria2_end | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 Hysteria2 结束端口无效。"
    cross_tuic_port="$(jq -er '.ports.cross.tuic | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 TUIC 端口无效。"
    cross_ss_port="$(jq -er '.ports.cross.ss2022 | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 SS2022 端口无效。"
    cross_anytls_port="$(jq -er '.ports.cross.anytls | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 AnyTLS 端口无效。"
    cross_trojan_port="$(jq -er '.ports.cross.trojan | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 Trojan 端口无效。"
    cross_vision_port="$(jq -er '.ports.cross.vless_reality_vision | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 VLESS Vision 端口无效。"
    cross_xhttp_port="$(jq -er '.ports.cross.vless_reality_xhttp | select(type == "number" and . == floor)' "$NEKO_STATE")" \
      || die "state.json 中的跨族 VLESS XHTTP 端口无效。"
    cross_ipv4_to_ipv6_token="$(jq -r '.subscription.ipv4_to_ipv6_token // empty' "$NEKO_STATE")"
    cross_ipv6_to_ipv4_token="$(jq -r '.subscription.ipv6_to_ipv4_token // empty' "$NEKO_STATE")"
    [[ "$cross_ipv4_to_ipv6_token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv4→IPv6 订阅令牌无效。"
    [[ "$cross_ipv6_to_ipv4_token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 IPv6→IPv4 订阅令牌无效。"
  fi

  initialize_port_reservations
  for ((port = hy2_start; port <= hy2_end; port++)); do
    NEKO_RESERVED_PORTS["$port"]=1
  done
  for port in "$tuic_port" "$ss_port" "$anytls_port" "$vision_port" "$xhttp_port"; do
    NEKO_RESERVED_PORTS["$port"]=1
  done
  if network_mode_has_cross_routes && (( current_schema == 4 )); then
    (( cross_hy2_start >= 10000 && cross_hy2_end <= 60000 \
      && cross_hy2_end - cross_hy2_start == 127 )) \
      || die "state.json 中的跨族 Hysteria2 端口范围无效。"
    for ((port = cross_hy2_start; port <= cross_hy2_end; port++)); do
      NEKO_RESERVED_PORTS["$port"]=1
    done
    for port in \
      "$cross_tuic_port" "$cross_ss_port" "$cross_anytls_port" \
      "$cross_trojan_port" "$cross_vision_port" "$cross_xhttp_port"; do
      (( port >= 10000 && port <= 60000 )) \
        || die "state.json 中存在范围无效的跨族代理端口。"
      NEKO_RESERVED_PORTS["$port"]=1
    done
  fi
  if [[ -n "$trojan_port" ]]; then
    NEKO_RESERVED_PORTS["$trojan_port"]=1
  else
    reserve_random_port trojan_port
  fi
  if [[ "$anyreality_enabled" == true ]]; then
    # initialize_port_reservations also sees the currently running Neko
    # listeners.  A preserved AnyReality port is therefore expected to be in
    # this map during an in-place upgrade; validate_proxy_port_layout below
    # still rejects real overlaps inside state.json.
    NEKO_RESERVED_PORTS["$anyreality_port"]=1
    if network_mode_has_cross_routes \
      && [[ "$cross_anyreality_port" =~ ^[0-9]+$ ]]; then
      NEKO_RESERVED_PORTS["$cross_anyreality_port"]=1
    fi
  fi

  if network_mode_has_cross_routes; then
    if (( current_schema != 4 )); then
      reserve_random_range 128 cross_hy2_start cross_hy2_end
      reserve_random_port cross_tuic_port
      reserve_random_port cross_ss_port
      reserve_random_port cross_anytls_port
      reserve_random_port cross_trojan_port
      reserve_random_port cross_vision_port
      reserve_random_port cross_xhttp_port
      cross_ipv4_to_ipv6_token="$(random_urlsafe 24)"
      cross_ipv6_to_ipv4_token="$(random_urlsafe 24)"
      if [[ "$anyreality_enabled" == true ]]; then
        reserve_random_port cross_anyreality_port
      fi
    fi
  fi

  stage_core_upgrade_set
  if [[ "$anyreality_enabled" != true ]]; then
    reserve_random_port anyreality_port
    if network_mode_has_cross_routes; then
      reserve_random_port cross_anyreality_port
    fi
    reality_key_binary="$(target_core_binary sing-box)"
    anyreality_pair="$("$reality_key_binary" generate reality-keypair)" \
      || die "无法生成 AnyReality REALITY 密钥。"
    anyreality_private="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<< "$anyreality_pair")"
    anyreality_public="$(awk -F': ' '/^PublicKey:/ {print $2}' <<< "$anyreality_pair")"
    [[ "$anyreality_private" =~ ^[A-Za-z0-9_-]{43}$ \
      && "$anyreality_public" =~ ^[A-Za-z0-9_-]{43}$ ]] \
      || die "无法解析 AnyReality REALITY 密钥。"
    anyreality_password="$(random_urlsafe 24)"
    anyreality_short_id="$(random_hex 8)"
  fi

  HY2_START="$hy2_start"
  HY2_END="$hy2_end"
  TUIC_PORT="$tuic_port"
  SS_PORT="$ss_port"
  ANYTLS_PORT="$anytls_port"
  TROJAN_PORT="$trojan_port"
  VISION_PORT="$vision_port"
  XHTTP_PORT="$xhttp_port"
  ANYREALITY_ENABLED=true
  ANYREALITY_PORT="$anyreality_port"
  ANYREALITY_PASSWORD="$anyreality_password"
  ANYREALITY_PRIVATE_KEY="$anyreality_private"
  ANYREALITY_PUBLIC_KEY="$anyreality_public"
  ANYREALITY_SHORT_ID="$anyreality_short_id"
  if network_mode_has_cross_routes; then
    CROSS_HY2_START="$cross_hy2_start"
    CROSS_HY2_END="$cross_hy2_end"
    CROSS_TUIC_PORT="$cross_tuic_port"
    CROSS_SS_PORT="$cross_ss_port"
    CROSS_ANYTLS_PORT="$cross_anytls_port"
    CROSS_TROJAN_PORT="$cross_trojan_port"
    CROSS_VISION_PORT="$cross_vision_port"
    CROSS_XHTTP_PORT="$cross_xhttp_port"
    CROSS_ANYREALITY_PORT="$cross_anyreality_port"
  fi
  validate_proxy_port_layout
  trojan_password="$(jq -r '.credentials.trojan_password // empty' "$NEKO_STATE")"
  if [[ -n "$trojan_password" ]]; then
    [[ "$trojan_password" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
      || die "state.json 中的 Trojan 密码格式无效。"
  else
    trojan_password="$(random_urlsafe 24)"
  fi
  resolve_strict_endpoints
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    assert_network_mode_kernel "$NETWORK_MODE"
    assert_strict_addresses_local "$NETWORK_MODE"
  fi
  BACKUP_DIR="$(mktemp -d "${NEKO_UPDATE_TMP_DIR%/}/neko-upgrade-backup.XXXXXX")"
  UPGRADE_FIREWALL_MANAGER="$(
    jq -r '.firewall.manager // "none"' "$NEKO_STATE"
  )"
  case "$UPGRADE_FIREWALL_MANAGER" in
    firewalld)
      firewalld_is_active \
        || die "原安装由 firewalld 管理，但 firewalld 当前未运行；未开始升级。"
      [[ -f "$FIREWALLD_SERVICE_FILE" && ! -L "$FIREWALLD_SERVICE_FILE" ]] \
        || die "现有 Neko firewalld 服务文件缺失或类型异常；未开始升级。"
      cp -a -- \
        "$FIREWALLD_SERVICE_FILE" "$BACKUP_DIR/neko-proxy-firewalld.xml"
      ;;
    ufw)
      ufw_is_active \
        || die "原安装由 UFW 管理，但 UFW 当前未运行；未开始升级。"
      [[ -f "$UFW_PROFILE_FILE" && ! -L "$UFW_PROFILE_FILE" ]] \
        || die "现有 Neko UFW 应用配置缺失或类型异常；未开始升级。"
      cp -a -- "$UFW_PROFILE_FILE" "$BACKUP_DIR/neko-proxy-ufw"
      ;;
    none)
      ;;
    *)
      die "state.json 记录了未知防火墙管理器：${UPGRADE_FIREWALL_MANAGER}"
      ;;
  esac
  cp -a -- "$NEKO_ETC" "$BACKUP_DIR/etc"
  cp -a -- "$NEKO_VAR/lego" "$BACKUP_DIR/lego"
  cp -a -- "$NEKO_LIBEXEC/lib" "$BACKUP_DIR/lib"
  [[ ! -e "$NEKO_LIBEXEC/panel" ]] \
    || cp -a -- "$NEKO_LIBEXEC/panel" "$BACKUP_DIR/panel"
  cp -a -- "$NEKO_LIBEXEC/versions.env" "$BACKUP_DIR/versions.env"
  cp -a -- "$NEKO_LIBEXEC/panel.sh" "$BACKUP_DIR/panel.sh"
  cp -a -- "$NEKO_LIBEXEC/renew.sh" "$BACKUP_DIR/renew.sh"
  [[ ! -e "$NEKO_LIBEXEC/diagnostics.sh" ]] \
    || cp -a -- "$NEKO_LIBEXEC/diagnostics.sh" "$BACKUP_DIR/diagnostics.sh"
  [[ ! -e "$NEKO_LIBEXEC/route-diagnostics.sh" ]] \
    || cp -a -- \
      "$NEKO_LIBEXEC/route-diagnostics.sh" "$BACKUP_DIR/route-diagnostics.sh"
  [[ ! -e "$NEKO_LIBEXEC/hysteria-dual.sh" ]] \
    || cp -a -- "$NEKO_LIBEXEC/hysteria-dual.sh" "$BACKUP_DIR/hysteria-dual.sh"
  [[ ! -e "$NEKO_LIBEXEC/akdns.sh" ]] \
    || cp -a -- "$NEKO_LIBEXEC/akdns.sh" "$BACKUP_DIR/akdns.sh"
  [[ ! -e "$NEKO_LIBEXEC/qrc" ]] \
    || cp -a -- "$NEKO_LIBEXEC/qrc" "$BACKUP_DIR/qrc"
  [[ ! -e "$NEKO_LIBEXEC/nexttrace-tiny" ]] \
    || cp -a -- \
      "$NEKO_LIBEXEC/nexttrace-tiny" "$BACKUP_DIR/nexttrace-tiny"
  [[ ! -e "$NEKO_SYSTEMD/neko-hysteria.service" ]] \
    || cp -a -- \
      "$NEKO_SYSTEMD/neko-hysteria.service" "$BACKUP_DIR/neko-hysteria.service"
  snapshot_core_binaries
  snapshot_upgrade_service_states
  ROLLBACK_READY=1

  install -d -m 0755 "$NEKO_LIBEXEC/panel"
  for library_file in \
    common.sh common-platform.sh common-network.sh common-acme.sh \
    common-credentials.sh common-download.sh common-subscription.sh \
    state.sh render.sh render-server.sh render-caddy.sh render-client.sh \
    render-route-model.sh render-subscriptions.sh firewall.sh transaction.sh; do
    install -m 0644 \
      "$SCRIPT_DIR/lib/$library_file" "$NEKO_LIBEXEC/lib/$library_file"
  done
  install -m 0755 "$SCRIPT_DIR/runtime/panel.sh" "$NEKO_LIBEXEC/panel.sh"
  for panel_module in \
    system.sh access.sh family.sh third-party.sh akdns-menu.sh route-guide.sh ui.sh; do
    install -m 0644 \
      "$SCRIPT_DIR/runtime/panel/$panel_module" "$NEKO_LIBEXEC/panel/$panel_module"
  done
  install -m 0755 \
    "$SCRIPT_DIR/runtime/route-diagnostics.sh" "$NEKO_LIBEXEC/route-diagnostics.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/renew.sh" "$NEKO_LIBEXEC/renew.sh"
  install -m 0755 \
    "$SCRIPT_DIR/runtime/hysteria-dual.sh" "$NEKO_LIBEXEC/hysteria-dual.sh"
  install -m 0755 "$SCRIPT_DIR/runtime/akdns.sh" "$NEKO_LIBEXEC/akdns.sh"
  install_staged_qrc
  install_staged_nexttrace
  rm -f -- "$NEKO_LIBEXEC/diagnostics.sh"
  install -m 0644 \
    "$SCRIPT_DIR/systemd/neko-hysteria.service" \
    "$NEKO_SYSTEMD/neko-hysteria.service"
  systemctl daemon-reload

  state_migrate_to_current \
    --source "$NEKO_STATE" --target "$NEKO_STATE" \
    --release "$NEKO_RELEASE" --acme-method "$ACME_METHOD" \
    --network-mode "$NETWORK_MODE" \
    --ipv4-domain "$SUBSCRIPTION_DOMAIN_IPV4" \
    --ipv6-domain "$SUBSCRIPTION_DOMAIN_IPV6" \
    --ipv4-address "$SUBSCRIPTION_IPV4_ADDRESS" \
    --ipv6-address "$SUBSCRIPTION_IPV6_ADDRESS" \
    --trojan-port "$trojan_port" --trojan-password "$trojan_password" \
    --cross-hysteria2-start "$cross_hy2_start" \
    --cross-hysteria2-end "$cross_hy2_end" \
    --cross-tuic-port "$cross_tuic_port" \
    --cross-ss2022-port "$cross_ss_port" \
    --cross-anytls-port "$cross_anytls_port" \
    --cross-trojan-port "$cross_trojan_port" \
    --cross-vision-port "$cross_vision_port" \
    --cross-xhttp-port "$cross_xhttp_port" \
    --ipv4-to-ipv6-token "$cross_ipv4_to_ipv6_token" \
    --ipv6-to-ipv4-token "$cross_ipv6_to_ipv4_token" \
    --anyreality-port "$anyreality_port" \
    --cross-anyreality-port "$cross_anyreality_port" \
    --anyreality-password "$anyreality_password" \
    --anyreality-private-key "$anyreality_private" \
    --anyreality-public-key "$anyreality_public" \
    --anyreality-short-id "$anyreality_short_id" \
    || die "state.json 逐版本迁移或最终完整校验失败。"

  # shellcheck source=lib/render.sh
  source "$NEKO_LIBEXEC/lib/render.sh"
  render_all
  rm -f -- \
    "$NEKO_ETC/subscriptions/mihomo.yaml" \
    "$NEKO_ETC/subscriptions/stash.yaml" \
    "$NEKO_ETC/subscriptions/shadowrocket.txt" \
    "$NEKO_ETC/subscriptions/shadowrocket.txt.before-ss2022-diagnostic" \
    "$NEKO_ETC/subscriptions/shadowrocket.txt.before-all-protocol-diagnostic"
  target_validation_dir="$NEKO_LIBEXEC"
  (( CORE_UPGRADE_REQUIRED == 0 )) \
    || target_validation_dir="$CORE_STAGE_BIN_DIR"
  upgrade_test_failpoint staged-config-validation \
    || die "测试注入：暂存核心配置校验失败。"
  validate_configs_with_core_dir "$target_validation_dir" \
    || die "目标核心未通过暂存配置与客户端订阅校验。"
  upgrade_test_event config-validated
  activate_staged_core_set || die "目标核心整组激活失败。"
  systemctl restart neko-caddy.service
  systemctl is-active --quiet neko-caddy.service

  load_state
  if ! certificate_has_strict_domains; then
    [[ "${NEKO_UPDATE_SKIP_ACME:-0}" != "1" ]] \
      || die "测试证书不包含当前已安装地址族所需的全部域名。"
    domain_args=()
    while IFS= read -r certificate_domain; do
      domain_args+=(--domains "$certificate_domain")
    done < <(active_certificate_domains)
    run_lego_acme "$NEKO_LIBEXEC/lego" webroot run \
      --path "$NEKO_VAR/lego" \
      --email "$ACME_EMAIL" \
      "${domain_args[@]}" \
      --accept-tos \
      --key-type EC256 \
      --force-cert-domains \
      --renew-force \
      --no-random-sleep
  fi
  certificate_has_strict_domains \
    || die "升级后的证书没有覆盖当前已安装地址族所需的全部域名。"
  openssl x509 -in "$CERT_FILE" -noout -checkend 604800 >/dev/null \
    || die "升级后的证书有效期不足 7 天。"
  while IFS= read -r certificate_domain; do
    openssl x509 -in "$CERT_FILE" -noout -checkhost "$certificate_domain" >/dev/null \
      || die "升级后的证书不包含 ${certificate_domain}。"
  done < <(active_certificate_domains)
  set_certificate_permissions

  render_all
  validate_installed_configs
  sync_managed_firewall_profile
  restart_and_verify_upgrade_services \
    || die "升级服务重启或健康检查失败。"
  if [[ "${NEKO_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    sleep 2
  fi
  for service in neko-caddy neko-sing-box neko-xray neko-hysteria; do
    systemctl is-active --quiet "${service}.service" \
      || die "${service} 升级后未保持运行。"
  done
  commit_target_versions_manifest || die "目标核心版本清单提交失败。"
  verify_committed_core_set \
    || die "核心版本清单与实际二进制身份不一致。"

  ROLLBACK_READY=0
  cleanup_qrc_stage
  cleanup_nexttrace_stage
  cleanup_core_stage
  cleanup_backup
  ok "已从 Neko ${current_release} 升级到 ${NEKO_RELEASE}。"
  show_subscription_links
  if (( current_schema == 1 )); then
    warn "旧的单域名订阅 URL 已停用；请在客户端导入新的严格 IPv4/IPv6 链接。"
  else
    info "旧版地址族专用 URL 继续可用；面板已显示兼容性更好的通用下载 URL。"
  fi
}

main "$@"
