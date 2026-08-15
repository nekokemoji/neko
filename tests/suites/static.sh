#!/usr/bin/env bash

# Static analysis and tool prerequisites.
# This file is sourced by tests/run.sh so the suites keep one shared fixture.
# shellcheck disable=SC2154
[[ "${NEKO_TEST_SUITE_CONTEXT:-}" == 1 ]] || {
  printf '请通过 tests/run.sh 运行测试套件。\n' >&2
  exit 1
}

printf '[1/10] Bash 语法、ShellCheck 与 Python YAML……\n'
mapfile -t shell_files <<< "$(find "$ROOT" -type f -name '*.sh' -print | sort)"
bash -n "${shell_files[@]}"
command -v shellcheck >/dev/null 2>&1 \
  || { printf '缺少必需测试工具 shellcheck。\n' >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 \
  || { printf '缺少必需 Python 模块 PyYAML。\n' >&2; exit 1; }
command -v zbarimg >/dev/null 2>&1 \
  || { printf '缺少必需测试工具 zbarimg。\n' >&2; exit 1; }
# Dynamic library sourcing and cross-file globals are intentional.
shellcheck -x -e SC1090,SC1091,SC2016,SC2034 "${shell_files[@]}"

bash "$ROOT/tests/release-contract.sh"
bash "$ROOT/tests/release-contract-failures.sh"
bash "$ROOT/tests/runtime-common.sh"
bash "$ROOT/tests/transaction-contract.sh"
bash "$ROOT/tests/production-facades.sh"
