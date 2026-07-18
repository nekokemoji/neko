#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "$ROOT/tests/platform.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

cases=(
  'debian|12|debian'
  'debian|13|debian'
  'ubuntu|24.04|debian'
  'ubuntu|26.04|debian'
  'rocky|9.6|rhel'
  'rocky|10.0|rhel'
  'almalinux|9.6|rhel'
  'almalinux|10.0|rhel'
)

count=0
for test_case in "${cases[@]}"; do
  IFS='|' read -r id version family <<< "$test_case"
  release_file="$WORK/${id}-${version}"
  printf 'ID=%q\nVERSION_ID=%q\n' "$id" "$version" > "$release_file"
  for machine in x86_64 aarch64; do
    result="$(
      OS_RELEASE_FILE="$release_file" ARCH_OVERRIDE="$machine" \
      bash -c 'source "$1"; detect_platform; printf "%s|%s|%s|%s" "$OS_ID" "$OS_VERSION" "$OS_FAMILY" "$ARCH"' \
      _ "$ROOT/lib/common.sh"
    )"
    if [[ "$machine" == "x86_64" ]]; then
      expected_arch=amd64
    else
      expected_arch=arm64
    fi
    expected="${id}|${version}|${family}|${expected_arch}"
    [[ "$result" == "$expected" ]] || {
      printf '平台检测失败：期望 %s，实际 %s\n' "$expected" "$result" >&2
      exit 1
    }
    ((count += 1))
  done
done

unsupported="$WORK/unsupported"
printf 'ID=ubuntu\nVERSION_ID=22.04\n' > "$unsupported"
if OS_RELEASE_FILE="$unsupported" ARCH_OVERRIDE=x86_64 \
  bash -c 'source "$1"; detect_platform' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
  printf '不受支持的平台被错误接受。\n' >&2
  exit 1
fi

source "$ROOT/lib/common.sh"
validate_domain node.example.com
for invalid_domain in 1.2.3.4 localhost bad..example.com '-bad.example.com'; do
  if validate_domain "$invalid_domain"; then
    printf '无效域名被错误接受：%s\n' "$invalid_domain" >&2
    exit 1
  fi
done

printf '平台矩阵：%d 个受支持组合通过，拒绝规则通过。\n' "$count"
