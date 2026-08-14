#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${NEKO_TEST_TOOLS_DIR:-$ROOT/tests/.tools}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-release-contract.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/root/lib" "$WORK/root/tests/fixtures" "$WORK/root/tests/suites"
cp -a -- \
  "$ROOT/versions.env" "$ROOT/bootstrap.sh" "$ROOT/README.md" \
  "$ROOT/TESTING.md" "$WORK/root/"
cp -a -- "$ROOT/lib/common.sh" "$ROOT/lib/state.sh" "$WORK/root/lib/"
cp -a -- "$ROOT/tests/fixtures/state.json" "$WORK/root/tests/fixtures/"
cp -a -- "$ROOT/tests/run.sh" "$WORK/root/tests/"
cp -a -- "$ROOT/tests/suites/." "$WORK/root/tests/suites/"

run_contract() {
  NEKO_RELEASE_CONTRACT_ROOT="$WORK/root" \
    XRAY_BIN="${XRAY_BIN_OVERRIDE:-$TOOLS/xray}" \
    SING_BOX_BIN="$TOOLS/sing-box" \
    HYSTERIA_BIN="$TOOLS/hysteria" \
    CADDY_BIN="$TOOLS/caddy" \
    LEGO_BIN="$TOOLS/lego" \
    MIHOMO_BIN="$TOOLS/mihomo" \
    QRC_BIN="$TOOLS/qrc" \
    NEXTTRACE_BIN="$TOOLS/nexttrace-tiny" \
    bash "$ROOT/tests/release-contract.sh"
}

expect_contract_failure() {
  local expected="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    printf '发布契约故障注入未被拒绝：%s\n' "$expected" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf '发布契约拒绝原因不明确；期望包含：%s\n实际输出：%s\n' \
      "$expected" "$output" >&2
    exit 1
  }
}

run_contract >/dev/null

cp -a -- "$WORK/root/tests/fixtures/state.json" "$WORK/state.json.good"
jq '.release = "9.9.9-drift"' "$WORK/state.json.good" \
  > "$WORK/root/tests/fixtures/state.json"
expect_contract_failure '当前状态 fixture release 与版本清单不一致' \
  run_contract
cp -a -- "$WORK/state.json.good" "$WORK/root/tests/fixtures/state.json"

cp -a -- "$WORK/root/versions.env" "$WORK/versions.env.good"
grep -E '^NEKO_RELEASE=' "$WORK/versions.env.good" \
  >> "$WORK/root/versions.env"
expect_contract_failure 'versions.env 存在重复键：NEKO_RELEASE' run_contract
cp -a -- "$WORK/versions.env.good" "$WORK/root/versions.env"

cat > "$WORK/fake-xray" <<'EOF'
#!/usr/bin/env bash
printf 'Xray 0.0.0-drift\n'
EOF
chmod 0755 "$WORK/fake-xray"
XRAY_BIN_OVERRIDE="$WORK/fake-xray" \
  expect_contract_failure 'Xray 实际身份与 versions.env 不一致' \
    run_contract

printf '发布契约的清单、状态与真实核心身份漂移故障注入通过。\n'
