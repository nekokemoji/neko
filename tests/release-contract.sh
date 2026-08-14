#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="${NEKO_RELEASE_CONTRACT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
XRAY="${XRAY_BIN:-$TOOLS/xray}"
SING_BOX="${SING_BOX_BIN:-$TOOLS/sing-box}"
HYSTERIA="${HYSTERIA_BIN:-$TOOLS/hysteria}"
CADDY="${CADDY_BIN:-$TOOLS/caddy}"
LEGO="${LEGO_BIN:-$TOOLS/lego}"
MIHOMO="${MIHOMO_BIN:-$TOOLS/mihomo}"
QRC="${QRC_BIN:-$TOOLS/qrc}"
NEXTTRACE="${NEXTTRACE_BIN:-$TOOLS/nexttrace-tiny}"

fail_contract() {
  printf '发布契约失败：%s\n' "$*" >&2
  exit 1
}

for required_file in \
  versions.env bootstrap.sh README.md TESTING.md lib/common.sh \
  tests/fixtures/state.json tests/run.sh; do
  [[ -s "$ROOT/$required_file" ]] \
    || fail_contract "缺少 ${required_file}"
done

declare -A manifest_keys=()
assignment_re='^([A-Z][A-Z0-9_]*)="([^"]*)"$'
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  [[ "$line" =~ $assignment_re ]] \
    || fail_contract "versions.env 包含非声明式内容：${line}"
  key="${BASH_REMATCH[1]}"
  [[ -z "${manifest_keys[$key]+x}" ]] \
    || fail_contract "versions.env 存在重复键：${key}"
  manifest_keys[$key]=1
done < "$ROOT/versions.env"

# versions.env has already been restricted to plain quoted assignments above.
# shellcheck source=versions.env
source "$ROOT/versions.env"

[[ "$NEKO_RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail_contract "NEKO_RELEASE 格式无效"
[[ "$NEKO_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || fail_contract "NEKO_SOURCE_COMMIT 格式无效"

required_version_sets=(
  XRAY SING_BOX HYSTERIA CADDY LEGO QRC NEXTTRACE MIHOMO
)
for prefix in "${required_version_sets[@]}"; do
  version_key="${prefix}_VERSION"
  amd64_key="${prefix}_AMD64_SHA256"
  arm64_key="${prefix}_ARM64_SHA256"
  [[ -n "${manifest_keys[$version_key]+x}" \
    && -n "${manifest_keys[$amd64_key]+x}" \
    && -n "${manifest_keys[$arm64_key]+x}" ]] \
    || fail_contract "${prefix} 缺少版本或双架构 SHA-256"
  [[ "${!version_key}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail_contract "${version_key} 格式无效"
done

for key in "${!manifest_keys[@]}"; do
  case "$key" in
    *_SHA256)
      [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] \
        || fail_contract "${key} 格式无效"
      ;;
    *_SOURCE_COMMIT)
      [[ "${!key}" =~ ^[0-9a-f]{40}$ ]] \
        || fail_contract "${key} 格式无效"
      ;;
  esac
done

for key in \
  AKDNS_VERSION AKDNS_SOURCE_COMMIT AKDNS_SHA256 \
  GOECS_SOURCE_COMMIT GOECS_SHA256 \
  NODEQUALITY_SOURCE_COMMIT NODEQUALITY_SHA256; do
  [[ -n "${manifest_keys[$key]+x}" ]] \
    || fail_contract "versions.env 缺少 ${key}"
done

mapfile -t bootstrap_commits < <(
  sed -nE 's/^NEKO_SOURCE_COMMIT="([0-9a-f]{40})"$/\1/p' \
    "$ROOT/bootstrap.sh"
)
(( ${#bootstrap_commits[@]} == 1 )) \
  || fail_contract "Bootstrap 源码提交声明不是唯一的 40 位提交"
[[ "${bootstrap_commits[0]}" == "$NEKO_SOURCE_COMMIT" ]] \
  || fail_contract "Bootstrap 源码提交与 versions.env 不一致"
grep -Fq "正在从 GitHub 下载固定版本 Neko ${NEKO_RELEASE}" \
  "$ROOT/bootstrap.sh" \
  || fail_contract "Bootstrap 显示版本与清单不一致"
grep -Fq "NEKO_RELEASE=\"${NEKO_RELEASE}\"" "$ROOT/bootstrap.sh" \
  || fail_contract "Bootstrap 下载后版本断言与清单不一致"
grep -Fq "当前 Neko 版本为 **${NEKO_RELEASE}**" "$ROOT/README.md" \
  || fail_contract "README 当前版本与清单不一致"
grep -Fq "# Neko ${NEKO_RELEASE} 测试范围" "$ROOT/TESTING.md" \
  || fail_contract "TESTING 标题版本与清单不一致"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
fixture_release="$(jq -er '.release | select(type == "string")' \
  "$ROOT/tests/fixtures/state.json")" \
  || fail_contract "当前状态 fixture 缺少 release"
fixture_schema="$(jq -er '.schema | select(type == "number")' \
  "$ROOT/tests/fixtures/state.json")" \
  || fail_contract "当前状态 fixture 缺少 schema"
[[ "$fixture_release" == "$NEKO_RELEASE" ]] \
  || fail_contract "当前状态 fixture release 与版本清单不一致"
[[ "$fixture_schema" == "$NEKO_STATE_SCHEMA" ]] \
  || fail_contract "当前状态 fixture schema 与运行时不一致"

suite_names=(static state acme render panel-transactions upgrade)
for suite in "${suite_names[@]}"; do
  [[ -s "$ROOT/tests/suites/${suite}.sh" ]] \
    || fail_contract "缺少测试套件 ${suite}"
  grep -Fxq "source \"\$ROOT/tests/suites/${suite}.sh\"" \
    "$ROOT/tests/run.sh" \
    || fail_contract "tests/run.sh 未按契约加载 ${suite} 套件"
done

assert_identity() {
  local label="$1" expected="$2" output
  shift 2
  if ! output="$(NO_COLOR=1 "$@" 2>&1)"; then
    fail_contract "${label} 无法报告版本身份"
  fi
  [[ "$output" == *"$expected"* ]] \
    || fail_contract "${label} 实际身份与 versions.env 不一致"
}

assert_identity Xray "$XRAY_VERSION" "$XRAY" version
assert_identity sing-box "$SING_BOX_VERSION" "$SING_BOX" version
assert_identity Hysteria "v${HYSTERIA_VERSION}" "$HYSTERIA" version
assert_identity Caddy "v${CADDY_VERSION}" "$CADDY" version
assert_identity lego "$LEGO_VERSION" "$LEGO" --version
assert_identity Mihomo "v${MIHOMO_VERSION}" "$MIHOMO" -v
assert_identity NextTrace "NextTrace v${NEXTTRACE_VERSION}" \
  "$NEXTTRACE" --version
assert_identity qrc '--output-format=<auto|ansi|sixel|unicode>' "$QRC" --help

printf '发布契约：版本清单、Bootstrap、状态版本、套件入口与真实工具身份一致。\n'
