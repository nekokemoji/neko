#!/usr/bin/env bash

# AKDNS-specific menu wrapper. The pinned AKDNS runtime remains isolated in
# runtime/akdns.sh. Loaded through runtime/panel.sh.

manage_akdns() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf 'AKDNS 智能 DNS 解锁（第三方、可选）\n'
    printf '===================================\n\n'
    printf 'AKDNS 会接管整台 VPS 的系统 DNS，不是只影响某一个代理协议。\n'
    printf 'Neko 只运行固定上游提交并校验 SHA-256；切换失败会自动恢复。\n'
    printf '上游菜单里的流媒体检测还会运行其选择的另一份第三方脚本。\n'
    printf '需要还原时请退出上游界面，回到这里选择 2，不要在上游选 7。\n\n'
    printf '1. 打开已固定并校验的 AKDNS 官方菜单\n'
    printf '2. 紧急恢复 Neko 保存的 AKDNS 启用前状态\n'
    printf '3. 查看 AKDNS 状态\n'
    printf '0. 返回\n\n'
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
      0|"") return 0 ;;
      1) "${NEKO_LIBEXEC}/akdns.sh" --run || true ;;
      2) "${NEKO_LIBEXEC}/akdns.sh" --restore || true ;;
      3) "${NEKO_LIBEXEC}/akdns.sh" --status || true ;;
      *)
        warn "请输入 0 到 3。"
        sleep 1
        continue
        ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回 AKDNS 菜单……" _ || true
  done
}
