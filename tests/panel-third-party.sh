#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-third-party.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/libexec/lib"
cp -a -- "$ROOT/lib/common.sh" "$ROOT/lib/render.sh" "$ROOT/lib/firewall.sh" \
  "$WORK/libexec/lib/"
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
chmod 0755 "$WORK/bin/curl" "$WORK/bin/goecs"
cat > "$WORK/libexec/route-diagnostics.sh" <<'EOF'
#!/usr/bin/env bash
printf 'neko-routes\n' >> "$NEKO_THIRD_PARTY_LOG"
EOF
chmod 0755 "$WORK/libexec/route-diagnostics.sh"

panel_output="$(
  printf '1\n\n2\n\n0\n' \
    | PATH="$WORK/bin:$PATH" \
      NEKO_LIBEXEC="$ROOT" \
      NEKO_PANEL_TMP_DIR="$WORK/tmp" \
      NEKO_THIRD_PARTY_LOG="$WORK/calls.log" \
      TERM=dumb \
      bash -c 'source "$1"; open_third_party_checks' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"

[[ "$panel_output" == *'1. GOECS 融合怪'* ]]
[[ "$panel_output" == *'2. NodeQuality 综合测试'* ]]
[[ "$panel_output" == *'3. Neko 三网线路检测'* ]]
grep -Fxq 'https://raw.githubusercontent.com/oneclickvirt/ecs/master/goecs.sh' \
  "$WORK/calls.log"
grep -Fxq 'https://run.NodeQuality.com' "$WORK/calls.log"
grep -Fxq 'script:install' "$WORK/calls.log"
grep -Fxq 'goecs:' "$WORK/calls.log"
grep -Fxq 'script:' "$WORK/calls.log"
if grep -Eq '确认|验证|UNINSTALL' <<< "$panel_output"; then
  printf '第三方体检前不应出现 Neko 的确认或验证提示。\n' >&2
  exit 1
fi

route_output="$(
  printf '3\n\n0\n' \
    | PATH="$WORK/bin:$PATH" \
      NEKO_LIBEXEC="$WORK/libexec" \
      NEKO_PANEL_TMP_DIR="$WORK/tmp" \
      NEKO_THIRD_PARTY_LOG="$WORK/calls.log" \
      TERM=dumb \
      bash -c 'source "$1"; open_third_party_checks' \
        _ "$ROOT/runtime/panel.sh" 2>&1
)"
[[ "$route_output" == *'第三方 VPS 体检 & Neko 自带体检'* ]]
grep -Fxq 'neko-routes' "$WORK/calls.log"

printf '面板第 7 项第三方与 Neko 六地三网线路入口测试通过。\n'
