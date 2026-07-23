#!/usr/bin/env bash

# Small, stable entrypoint for first-time users.  It downloads one pinned Neko
# source revision and then hands the terminal directly to the real installer,
# so interactive domain/email prompts continue to read from the user's TTY.

set -Eeuo pipefail
umask 0077

NEKO_REPOSITORY="nekokemoji/neko"
NEKO_SOURCE_COMMIT="f965d0650ffc8ee3db63e35957b192fd4f534c28"
NEKO_BOOTSTRAP_WORK_BASE="${NEKO_BOOTSTRAP_WORK_BASE:-/var/tmp}"
NEKO_BOOTSTRAP_ARCHIVE="${NEKO_BOOTSTRAP_ARCHIVE:-}"
WORKDIR=""

die_bootstrap() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

install_bootstrap_dependencies() {
  local -a required_commands=(tar gzip mktemp mkdir grep rm cp)
  local -a missing_commands=()
  local -a packages=(ca-certificates)
  local command_name

  if [[ -z "$NEKO_BOOTSTRAP_ARCHIVE" ]]; then
    required_commands+=(curl)
  fi
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 \
      || missing_commands+=("$command_name")
  done
  (( ${#missing_commands[@]} > 0 )) || return 0

  printf '[信息] 系统缺少首次安装工具，正在自动补齐：%s\n' \
    "${missing_commands[*]}"
  for command_name in "${missing_commands[@]}"; do
    case "$command_name" in
      curl|tar|gzip|grep)
        packages+=("$command_name")
        ;;
      mktemp|mkdir|rm|cp)
        if [[ " ${packages[*]} " != *" coreutils "* ]]; then
          packages+=(coreutils)
        fi
        ;;
    esac
  done

  if command -v apt-get >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get update \
      || ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${packages[@]}"; then
      die_bootstrap "自动安装基础工具失败；请检查系统软件源后重试。"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! dnf -y install "${packages[@]}"; then
      die_bootstrap "自动安装基础工具失败；请检查系统软件源后重试。"
    fi
  elif command -v microdnf >/dev/null 2>&1; then
    if ! microdnf -y install "${packages[@]}"; then
      die_bootstrap "自动安装基础工具失败；请检查系统软件源后重试。"
    fi
  else
    die_bootstrap \
      "系统缺少基础工具（${missing_commands[*]}），且找不到 apt-get、dnf 或 microdnf。"
  fi

  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die_bootstrap "自动安装后仍缺少基础命令：${command_name}"
  done
}

cleanup() {
  local base="${NEKO_BOOTSTRAP_WORK_BASE%/}"
  if [[ -n "$WORKDIR" && "$WORKDIR" == "$base"/neko-bootstrap.* ]]; then
    rm -rf -- "$WORKDIR"
  fi
}

trap cleanup EXIT

if (( EUID != 0 )) && [[ "${NEKO_BOOTSTRAP_TEST_MODE:-0}" != 1 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- bash "$0" "$@"
  fi
  die_bootstrap "请切换到 root 后重新执行；当前系统没有 sudo。"
fi

install_bootstrap_dependencies
[[ -d "$NEKO_BOOTSTRAP_WORK_BASE" && -w "$NEKO_BOOTSTRAP_WORK_BASE" ]] \
  || die_bootstrap "临时目录不可写：${NEKO_BOOTSTRAP_WORK_BASE}"

WORKDIR="$(mktemp -d "${NEKO_BOOTSTRAP_WORK_BASE%/}/neko-bootstrap.XXXXXX")"
mkdir -p "$WORKDIR/source"

if [[ -n "$NEKO_BOOTSTRAP_ARCHIVE" ]]; then
  [[ -r "$NEKO_BOOTSTRAP_ARCHIVE" ]] \
    || die_bootstrap "测试安装包不可读：${NEKO_BOOTSTRAP_ARCHIVE}"
  cp -- "$NEKO_BOOTSTRAP_ARCHIVE" "$WORKDIR/neko.tar.gz"
else
  printf '[信息] 正在从 GitHub 下载固定版本 Neko 1.2.1……\n'
  curl --fail --location --silent --show-error \
    --retry 4 --connect-timeout 15 --proto '=https' --tlsv1.2 \
    "https://github.com/${NEKO_REPOSITORY}/archive/${NEKO_SOURCE_COMMIT}.tar.gz" \
    --output "$WORKDIR/neko.tar.gz"
fi

tar --no-same-owner -xzf "$WORKDIR/neko.tar.gz" \
  --strip-components=1 -C "$WORKDIR/source"

for required_file in \
  install.sh versions.env \
  lib/common.sh lib/render.sh lib/firewall.sh \
  runtime/panel.sh runtime/renew.sh runtime/hysteria-dual.sh \
  systemd/neko-caddy.service systemd/neko-sing-box.service \
  systemd/neko-xray.service systemd/neko-hysteria.service \
  systemd/neko-renew.service systemd/neko-renew.timer; do
  [[ -s "$WORKDIR/source/$required_file" ]] \
    || die_bootstrap "下载的项目不完整，缺少 ${required_file}。"
done
grep -Fq 'NEKO_RELEASE="1.2.1"' "$WORKDIR/source/versions.env" \
  || die_bootstrap "下载的项目版本不是预期的 Neko 1.2.1。"

if [[ "${NEKO_BOOTSTRAP_TEST_MODE:-0}" == 1 ]]; then
  bash -n "$WORKDIR/source/install.sh" \
    "$WORKDIR/source/lib/common.sh" \
    "$WORKDIR/source/lib/render.sh" \
    "$WORKDIR/source/lib/firewall.sh"
  printf '[测试] Bootstrap 已成功校验固定安装包。\n'
  exit 0
fi

printf '[信息] 下载完成，即将进入交互安装。\n'
bash "$WORKDIR/source/install.sh" "$@"
