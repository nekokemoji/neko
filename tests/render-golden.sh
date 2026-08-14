#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED="$ROOT/tests/fixtures/render-golden.sha256"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neko-render-golden.XXXXXX")"
ACTUAL="$WORK/render-golden.sha256"
trap 'rm -rf -- "$WORK"' EXIT

for command_name in find jq sed sha256sum sort; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Golden 渲染测试缺少命令：%s\n' "$command_name" >&2
    exit 1
  }
done

prepare_mode() {
  local mode="$1" target="$2"
  mkdir -p "$target/etc"
  case "$mode" in
    ipv4-only)
      jq '
        .network.mode = "ipv4-only"
        | .subscription.ipv6_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv6_domain = null
        | .subscription.ipv6_address = null
        | .ports.cross = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    ipv6-only)
      jq '
        .network.mode = "ipv6-only"
        | .subscription.ipv4_token = null
        | .subscription.ipv4_to_ipv6_token = null
        | .subscription.ipv6_to_ipv4_token = null
        | .subscription.ipv4_domain = null
        | .subscription.ipv4_address = null
        | .ports.cross = null
      ' "$ROOT/tests/fixtures/state.json" > "$target/etc/state.json"
      ;;
    dual)
      cp -a -- "$ROOT/tests/fixtures/state.json" "$target/etc/state.json"
      ;;
    *) return 64 ;;
  esac
}

render_mode() {
  local target="$1"
  NEKO_ETC="$target/etc" \
    NEKO_VAR="$target/var" \
    NEKO_STATE="$target/etc/state.json" \
    NEKO_USER=root \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      source "$2"
      render_all
    ' _ "$ROOT/lib/common.sh" "$ROOT/lib/render.sh"
}

normalized_sha256() {
  local target="$1" file="$2"
  sed "s#${target}#@NEKO_ROOT@#g" "$file" | sha256sum | awk '{print $1}'
}

: > "$ACTUAL"
for mode in ipv4-only ipv6-only dual; do
  target="$WORK/$mode"
  prepare_mode "$mode" "$target"
  render_mode "$target"
  while IFS= read -r file; do
    relative_path="${file#"$target/etc/"}"
    printf '%s  %s/%s\n' \
      "$(normalized_sha256 "$target" "$file")" \
      "$mode" "$relative_path" >> "$ACTUAL"
  done < <(
    find "$target/etc/config" "$target/etc/subscriptions" \
      -type f -print | sort
  )
done

if [[ "${1:-}" == --print ]]; then
  cat "$ACTUAL"
  exit 0
fi

[[ -s "$EXPECTED" ]] || {
  printf '缺少 Golden 清单：%s\n' "$EXPECTED" >&2
  exit 1
}
expected_digest="$(sha256sum "$EXPECTED" | awk '{print $1}')"
actual_digest="$(sha256sum "$ACTUAL" | awk '{print $1}')"
if [[ "$actual_digest" != "$expected_digest" ]]; then
  printf '%s\n' 'Golden 渲染结果不一致。' >&2
  printf '%s\n' '--- expected ---' >&2
  cat "$EXPECTED" >&2
  printf '%s\n' '--- actual ---' >&2
  cat "$ACTUAL" >&2
  exit 1
fi
printf '三种网络模式的规范化配置与订阅 Golden 完全一致。\n'
