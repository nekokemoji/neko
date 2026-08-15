#!/usr/bin/env bash

# Architecture-aware verified download helpers. Loaded through lib/common.sh.

sha_for_arch() {
  local component="$1" key
  key="${component}_${ARCH^^}_SHA256"
  printf '%s' "${!key:-}"
}

download_verified() {
  local label="$1" url="$2" expected="$3" output="$4"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "${label} 缺少固定 SHA-256。"
  info "下载 ${label}……"
  curl --fail --location --silent --show-error \
    --retry 4 --retry-all-errors --connect-timeout 15 \
    --proto '=https' --tlsv1.2 \
    --output "$output" "$url"
  printf '%s  %s\n' "$expected" "$output" | sha256sum --check --status \
    || die "${label} 的 SHA-256 校验失败。"
}

download_optional_verified() {
  local label="$1" url="$2" expected="$3" output="$4"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    warn "${label} 缺少固定 SHA-256；跳过这个可选组件。"
    return 1
  fi
  info "下载可选组件 ${label}……"
  if ! curl --fail --location --silent --show-error \
      --retry 4 --retry-all-errors --connect-timeout 15 \
      --max-time 120 --speed-limit 1024 --speed-time 30 \
      --proto '=https' --tlsv1.2 \
      --output "$output" "$url"; then
    rm -f -- "$output"
    warn "${label} 下载失败；Neko 仍会继续安装，文字订阅链接不受影响。"
    return 1
  fi
  if ! printf '%s  %s\n' "$expected" "$output" \
      | sha256sum --check --status; then
    rm -f -- "$output"
    warn "${label} 的 SHA-256 校验失败；已丢弃文件，文字订阅链接不受影响。"
    return 1
  fi
  return 0
}
