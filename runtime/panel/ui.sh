#!/usr/bin/env bash

# Top-level terminal menu and dispatch. Loaded through runtime/panel.sh.

draw_menu() {
  load_state
  clear 2>/dev/null || true
  printf 'Neko 终端控制面板\n'
  printf '=================\n'
  printf '当前网络：%s\n\n' "$(network_mode_label)"
  printf '0. 退出\n'
  printf '1. 查看当前严格订阅链接与二维码\n'
  printf '2. 开启 BBRv1\n'
  printf '3. 订阅与节点访问管理\n'
  printf '4. 刷新已安装地址族端点\n'
  printf '5. IPv4/IPv6 安装管理\n'
  printf '6. 卸载全部协议\n'
  printf '7. 第三方 VPS 体检 & Neko 自带体检\n'
  printf '8. 双栈线路怎么选？（同时拥有 IPv4 和 IPv6 时查看）\n'
  printf '9. AKDNS 智能 DNS 解锁（第三方、可选）\n'
  printf '\n'
}

main() {
  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -- "$0" "$@"
    fi
    die "neko 控制面板需要 root 权限。"
  fi
  [[ -r "$NEKO_STATE" ]] || die "Neko 尚未完整安装。"
  while true; do
    draw_menu
    read -r -p "请选择 [0-9]：" choice
    case "$choice" in
      0) exit 0 ;;
      1)
        subscription_qr_menu
        continue
        ;;
      2) enable_bbr ;;
      3) manage_subscription_access ;;
      4) refresh_subscription_endpoints ;;
      5) manage_address_families ;;
      6) uninstall_neko ;;
      7)
        open_third_party_checks
        continue
        ;;
      8)
        show_route_guide
        continue
        ;;
      9)
        manage_akdns
        continue
        ;;
      *) warn "请输入 0 到 9。" ;;
    esac
    printf '\n'
    read -r -p "按 Enter 返回菜单……" _
  done
}
