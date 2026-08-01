#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_ID="$1"
EXPECTED_VERSION="$2"
EXPECTED_FAMILY="$3"
EXPECTED_ARCH="${4:-amd64}"

[[ "$(id -u)" == 0 ]] || {
  printf '完整 VM 冒烟测试必须以 root 运行。\n' >&2
  exit 1
}
[[ "$(< /proc/1/comm)" == systemd ]] || {
  printf 'PID 1 不是 systemd；拒绝把容器或用户态模拟标记为完整 VM。\n' >&2
  exit 1
}

system_state="$(timeout 30s systemctl is-system-running --wait 2>/dev/null || true)"
case "$system_state" in
  running|degraded) ;;
  *)
    printf 'systemd 尚未进入稳定状态：%s\n' "${system_state:-unknown}" >&2
    exit 1
    ;;
esac

# shellcheck source=versions.env
source "$ROOT/versions.env"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
ARCH_OVERRIDE="$EXPECTED_ARCH"
detect_platform

[[ "$OS_ID" == "$EXPECTED_ID" ]]
[[ "$OS_VERSION" == "$EXPECTED_VERSION" || "$OS_VERSION" == "$EXPECTED_VERSION".* ]]
[[ "$OS_FAMILY" == "$EXPECTED_FAMILY" ]]
[[ "$ARCH" == "$EXPECTED_ARCH" ]]

mapfile -t shell_files < <(find "$ROOT" -type f -name '*.sh' -print | sort)
bash -n "${shell_files[@]}"

for ((attempt = 0; attempt < 250; attempt++)); do
  fast_failure_output=""
  fast_failure_rc=0
  fast_failure_output="$(
    NEKO_ACME_TIMEOUT_SECONDS=20 \
      run_acme_command_guarded \
        "$ROOT/tests/fixtures/lego-fast-failure.sh" 2>&1
  )" || fast_failure_rc=$?
  (( fast_failure_rc == 42 ))
  [[ "$fast_failure_output" == *'9109: Invalid access token'* ]]
  [[ "$fast_failure_output" == *'Cloudflare 拒绝了 DNS API Token'* ]]
  [[ "$fast_failure_output" != *'Bad file descriptor'* ]]
done

rate_limit_started=$SECONDS
rate_limit_output=""
rate_limit_rc=0
rate_limit_output="$(
  NEKO_ACME_TIMEOUT_SECONDS=20 \
    run_acme_command_guarded \
      "$ROOT/tests/fixtures/lego-rate-limited.sh" 2>&1
)" || rate_limit_rc=$?
(( rate_limit_rc == ACME_RATE_LIMIT_EXIT ))
(( SECONDS - rate_limit_started < 5 ))
[[ "$rate_limit_output" == *'脚本已停止长时间等待'* ]]

timeout_output=""
timeout_rc=0
timeout_output="$(
  NEKO_ACME_TIMEOUT_SECONDS=1 \
    run_acme_command_guarded "$ROOT/tests/fixtures/lego-timeout.sh" 2>&1
)" || timeout_rc=$?
(( timeout_rc == ACME_TIMEOUT_EXIT ))
[[ "$timeout_output" == *'证书申请超过 1 秒'* ]]

# Parse every shipped unit with the guest's real systemd. Install disposable
# executable placeholders only so verify can distinguish syntax and sandbox
# errors from deliberately absent production payloads.
if ! id neko-proxy >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin neko-proxy
fi
install -d -m 0755 /usr/local/libexec/neko
install -m 0755 \
  "$ROOT/runtime/renew.sh" \
  "$ROOT/runtime/hysteria-dual.sh" \
  /usr/local/libexec/neko/
for binary in caddy sing-box xray hysteria; do
  install -m 0755 /usr/bin/true "/usr/local/libexec/neko/${binary}"
done

unit_verify_output=""
if ! unit_verify_output="$(
  systemd-analyze verify \
    "$ROOT"/systemd/neko-*.service \
    "$ROOT"/systemd/neko-*.timer 2>&1
)"; then
  printf '%s\n' "$unit_verify_output" >&2
  exit 1
fi

systemd-run --quiet --unit=neko-vm-smoke.service \
  --wait --collect /usr/bin/true

printf '完整 VM 通过：%s %s / %s（systemd %s，Bash %s）\n' \
  "$OS_ID" "$OS_VERSION" "$ARCH" \
  "$(systemd --version | sed -n '1s/.* //p')" "$BASH_VERSION"
