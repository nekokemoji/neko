#!/usr/bin/env bash

# Explicitly confirmed third-party VPS checks and the built-in diagnostics
# launcher. Loaded through runtime/panel.sh.

load_third_party_manifest() {
  local manifest="${NEKO_LIBEXEC}/versions.env"
  [[ -r "$manifest" ]] || {
    warn "缺少第三方入口版本清单：${manifest}"
    return 1
  }
  # Installed by Neko as a root-owned, non-writable release manifest.
  # shellcheck source=versions.env
  source "$manifest"
  [[ "${GOECS_SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ \
    && "${GOECS_SHA256:-}" =~ ^[0-9a-f]{64}$ \
    && "${NODEQUALITY_SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ \
    && "${NODEQUALITY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    warn "第三方入口版本清单格式无效；未下载或执行。"
    return 1
  }
}

prepare_third_party_entry() {
  local label="$1" source_url="$2" commit="$3" expected_sha="$4"
  local confirmation="$5" script="$6" transitive_boundary="$7"
  local actual_sha answer="" command_name

  for command_name in curl sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
      warn "${label} 入口缺少校验命令：${command_name}"
      return 1
    }
  done
  if ! curl --fail --location --silent --show-error \
      --retry 4 --connect-timeout 20 \
      "$source_url" --output "$script"; then
    warn "${label} 固定入口脚本下载失败。"
    return 1
  fi
  if ! chmod 0600 "$script"; then
    warn "${label} 固定入口临时文件权限设置失败；已拒绝执行。"
    return 1
  fi
  if ! actual_sha="$(sha256sum "$script")"; then
    warn "${label} 固定入口 SHA-256 计算失败；已拒绝执行。"
    return 1
  fi
  actual_sha="${actual_sha%% *}"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    warn "${label} 固定入口 SHA-256 不匹配；已拒绝执行。"
    return 1
  fi

  printf '\n%s 第三方 root 脚本\n' "$label"
  printf '来源：%s\n' "$source_url"
  printf '提交：%s\n' "$commit"
  printf '入口 SHA-256（已验证）：%s\n' "$actual_sha"
  warn "入口脚本已固定并校验，但其运行期间仍会${transitive_boundary}。"
  warn "第三方代码可能安装依赖、修改系统、发起公网请求、跑满 CPU/磁盘或上传测试结果。"
  read -r -p "输入 ${confirmation} 才以 root 执行（直接 Enter 取消）：" answer \
    || answer=""
  if [[ "$answer" != "$confirmation" ]]; then
    warn "已取消 ${label}；固定入口临时文件将被删除，未执行第三方代码。"
    return 1
  fi
}

run_goecs() {
  local script source_url
  load_third_party_manifest || return 1
  source_url="https://raw.githubusercontent.com/oneclickvirt/ecs/${GOECS_SOURCE_COMMIT}/goecs.sh"
  script="$(mktemp "${NEKO_PANEL_TMP_DIR%/}/neko-goecs.XXXXXX.sh")"
  if ! prepare_third_party_entry \
      "GOECS" "$source_url" "$GOECS_SOURCE_COMMIT" "$GOECS_SHA256" \
      "RUN-GOECS" "$script" \
      "查询 releases/latest，并从 GitHub Release 或第三方镜像下载未由 Neko 校验的 goecs 二进制"; then
    rm -f -- "$script"
    return 1
  fi
  if ! noninteractive=true bash "$script" install; then
    rm -f -- "$script"
    warn "GOECS 安装或更新失败。"
    return 1
  fi
  rm -f -- "$script"
  command -v goecs >/dev/null 2>&1 || {
    warn "GOECS 安装完成后没有找到 goecs 命令。"
    return 1
  }
  goecs
}

run_nodequality() {
  local script source_url rc=0
  load_third_party_manifest || return 1
  source_url="https://raw.githubusercontent.com/LloydAsp/NodeQuality/${NODEQUALITY_SOURCE_COMMIT}/NodeQuality.sh"
  script="$(mktemp "${NEKO_PANEL_TMP_DIR%/}/neko-nodequality.XXXXXX.sh")"
  if ! prepare_third_party_entry \
      "NodeQuality" "$source_url" "$NODEQUALITY_SOURCE_COMMIT" \
      "$NODEQUALITY_SHA256" "RUN-NODEQUALITY" "$script" \
      "从 main、Check.Place 等地址下载可变脚本/测试环境，并可能上传测试结果"; then
    rm -f -- "$script"
    return 1
  fi
  bash "$script" || rc=$?
  rm -f -- "$script"
  return "$rc"
}

open_third_party_checks() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '第三方 VPS 体检 & Neko 自带体检\n'
    printf '================================\n\n'
    printf '1. GOECS 融合怪（固定入口，执行前确认）\n'
    printf '2. NodeQuality 综合测试（固定入口，执行前确认）\n'
    printf '3. Neko 三网线路检测\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
      0|"") return 0 ;;
      1) run_goecs || true ;;
      2) run_nodequality || true ;;
      3)
        if [[ -x "${NEKO_LIBEXEC}/route-diagnostics.sh" ]]; then
          "${NEKO_LIBEXEC}/route-diagnostics.sh" || true
        else
          warn "Neko 三网线路检测组件不可用；代理服务不受影响。"
        fi
        ;;
      *)
        warn "请输入 0 到 3。"
        sleep 1
        continue
        ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回 VPS 体检菜单……" _ || true
  done
}
