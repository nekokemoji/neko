#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-third-party.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# shellcheck source=versions.env
source "$ROOT/versions.env"

mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/libexec/lib"
cp -a -- \
  "$ROOT/lib/"*.sh "$WORK/libexec/lib/"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
while (( $# > 0 )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$NEKO_THIRD_PARTY_LOG"
cat > "$output" <<'SCRIPT'
#!/usr/bin/env bash
printf 'script:%s\n' "$*" >> "$NEKO_THIRD_PARTY_LOG"
SCRIPT
EOF
cat > "$WORK/bin/goecs" <<'EOF'
#!/usr/bin/env bash
printf 'goecs:%s\n' "$*" >> "$NEKO_THIRD_PARTY_LOG"
EOF
cat > "$WORK/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  *neko-goecs.*.sh) expected="$NEKO_TEST_GOECS_SHA256" ;;
  *neko-nodequality.*.sh) expected="$NEKO_TEST_NODEQUALITY_SHA256" ;;
  *) command sha256sum "$@"; exit ;;
esac
if [[ "${NEKO_THIRD_PARTY_TAMPER:-0}" == 1 ]]; then
  expected="0000000000000000000000000000000000000000000000000000000000000000"
fi
printf '%s  %s\n' "$expected" "$1"
EOF
chmod 0755 "$WORK/bin/curl" "$WORK/bin/goecs" "$WORK/bin/sha256sum"
cat > "$WORK/libexec/route-diagnostics.sh" <<'EOF'
#!/usr/bin/env bash
printf 'neko-routes\n' >> "$NEKO_THIRD_PARTY_LOG"
EOF
chmod 0755 "$WORK/libexec/route-diagnostics.sh"

panel_output="$(
  printf '1\nRUN-GOECS\n\n2\nRUN-NODEQUALITY\n\n0\n' \
    | PATH="$WORK/bin:$PATH" \
      NEKO_LIBEXEC="$ROOT" \
      NEKO_PANEL_TMP_DIR="$WORK/tmp" \
      NEKO_THIRD_PARTY_LOG="$WORK/calls.log" \
      NEKO_TEST_GOECS_SHA256="$GOECS_SHA256" \
      NEKO_TEST_NODEQUALITY_SHA256="$NODEQUALITY_SHA256" \
      TERM=dumb \
      bash -c 'source "$1"; open_third_party_checks' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"

[[ "$panel_output" == *'1. GOECS 融合怪（固定入口，执行前确认）'* ]]
[[ "$panel_output" == *'2. NodeQuality 综合测试（固定入口，执行前确认）'* ]]
[[ "$panel_output" == *'3. Neko 三网线路检测'* ]]
grep -Fxq "https://raw.githubusercontent.com/oneclickvirt/ecs/${GOECS_SOURCE_COMMIT}/goecs.sh" \
  "$WORK/calls.log"
grep -Fxq "https://raw.githubusercontent.com/LloydAsp/NodeQuality/${NODEQUALITY_SOURCE_COMMIT}/NodeQuality.sh" \
  "$WORK/calls.log"
grep -Fxq 'script:install' "$WORK/calls.log"
grep -Fxq 'goecs:' "$WORK/calls.log"
grep -Fxq 'script:' "$WORK/calls.log"
[[ "$panel_output" == *"提交：${GOECS_SOURCE_COMMIT}"* ]]
[[ "$panel_output" == *"入口 SHA-256（已验证）：${GOECS_SHA256}"* ]]
[[ "$panel_output" == *"提交：${NODEQUALITY_SOURCE_COMMIT}"* ]]
[[ "$panel_output" == *"入口 SHA-256（已验证）：${NODEQUALITY_SHA256}"* ]]
[[ "$panel_output" == *'仍会查询 releases/latest'* ]]
[[ "$panel_output" == *'仍会从 main、Check.Place 等地址下载可变脚本/测试环境'* ]]
if find "$WORK/tmp" -mindepth 1 -print -quit | grep -q .; then
  printf '第三方入口执行后没有清理 root-only 临时文件。\n' >&2
  exit 1
fi

cancel_output="$(
  printf '1\n\n\n0\n' \
    | PATH="$WORK/bin:$PATH" \
      NEKO_LIBEXEC="$ROOT" \
      NEKO_PANEL_TMP_DIR="$WORK/tmp" \
      NEKO_THIRD_PARTY_LOG="$WORK/cancel.log" \
      NEKO_TEST_GOECS_SHA256="$GOECS_SHA256" \
      NEKO_TEST_NODEQUALITY_SHA256="$NODEQUALITY_SHA256" \
      TERM=dumb \
      bash -c 'source "$1"; open_third_party_checks' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"
[[ "$cancel_output" == *'已取消 GOECS'* ]]
grep -Fxq "https://raw.githubusercontent.com/oneclickvirt/ecs/${GOECS_SOURCE_COMMIT}/goecs.sh" \
  "$WORK/cancel.log"
if grep -Eq '^(script|goecs):' "$WORK/cancel.log"; then
  printf '未输入专用确认词时仍执行了第三方代码。\n' >&2
  exit 1
fi

set +e
tamper_output="$(
  printf 'RUN-GOECS\n' \
    | PATH="$WORK/bin:$PATH" \
      NEKO_LIBEXEC="$ROOT" \
      NEKO_PANEL_TMP_DIR="$WORK/tmp" \
      NEKO_THIRD_PARTY_LOG="$WORK/tamper.log" \
      NEKO_TEST_GOECS_SHA256="$GOECS_SHA256" \
      NEKO_TEST_NODEQUALITY_SHA256="$NODEQUALITY_SHA256" \
      NEKO_THIRD_PARTY_TAMPER=1 \
      bash -c 'source "$1"; run_goecs' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"
tamper_rc=$?
set -e
(( tamper_rc != 0 ))
[[ "$tamper_output" == *'SHA-256 不匹配；已拒绝执行'* ]]
if grep -Eq '^(script|goecs):' "$WORK/tamper.log"; then
  printf 'SHA-256 不匹配时仍执行了第三方代码。\n' >&2
  exit 1
fi

route_output="$(
  printf '3\n\n0\n' \
    | PATH="$WORK/bin:$PATH" \
      NEKO_LIBEXEC="$WORK/libexec" \
      NEKO_PANEL_TMP_DIR="$WORK/tmp" \
      NEKO_THIRD_PARTY_LOG="$WORK/calls.log" \
      NEKO_TEST_GOECS_SHA256="$GOECS_SHA256" \
      NEKO_TEST_NODEQUALITY_SHA256="$NODEQUALITY_SHA256" \
      TERM=dumb \
      bash -c 'source "$1"; open_third_party_checks' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"
[[ "$route_output" == *'第三方 VPS 体检 & Neko 自带体检'* ]]
grep -Fxq 'neko-routes' "$WORK/calls.log"

printf '面板第 7 项固定第三方入口、显式确认与 Neko 线路入口测试通过。\n'
