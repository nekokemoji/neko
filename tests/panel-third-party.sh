#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-third-party.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/tmp"
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

printf '面板第 7 项直接运行 GOECS 与 NodeQuality 测试通过。\n'
