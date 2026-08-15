#!/usr/bin/env bash

# Dual-stack route recommendation and user guide. Loaded through
# runtime/panel.sh.

generate_anyreality_pair() {
  local output private_key public_key
  output="$("$NEKO_LIBEXEC/sing-box" generate reality-keypair)"
  private_key="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<< "$output")"
  public_key="$(awk -F': ' '/^PublicKey:/ {print $2}' <<< "$output")"
  [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  [[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  printf '%s %s\n' "$private_key" "$public_key"
}
show_route_recommendation() {
  local client_choice client blocked sent recommended backup
  local recommended_label backup_label recommended_url backup_url

  load_state
  if ! network_mode_has_cross_routes; then
    printf '\n当前安装不是 IPv4 + IPv6 双栈，不能生成四种线路组合。\n'
    printf '功能 8 只适用于同时拥有可用 IPv4 和 IPv6 的 VPS。\n'
    read -r -p "按 Enter 返回菜单……" _ || true
    return 0
  fi

  printf '\n选择所需的订阅链接：\n\n'
  printf '1. Shadowrocket\n'
  printf '2. Stash\n'
  printf '3. Mihomo\n'
  printf '4. sing-box\n'
  printf '0. 退出\n\n'
  read -r -p "请选择 [0-4]：" client_choice
  case "$client_choice" in
    0|"") return 0 ;;
    1) client=shadowrocket ;;
    2) client=stash ;;
    3) client=mihomo ;;
    4) client=sing-box ;;
    *) warn "请输入 0 到 4。"; return 0 ;;
  esac

  printf '\n哪个入口 IP 被墙？\n\n1. IPv4\n2. IPv6\n0. 退出\n\n'
  read -r -p "请选择 [0-2]：" blocked
  case "$blocked" in
    0|"") return 0 ;;
    1) blocked=ipv4 ;;
    2) blocked=ipv6 ;;
    *) warn "请输入 0 到 2。"; return 0 ;;
  esac

  printf '\n哪个出口 IP 被“送中”？\n\n1. IPv4\n2. IPv6\n0. 退出\n\n'
  read -r -p "请选择 [0-2]：" sent
  case "$sent" in
    0|"") return 0 ;;
    1) sent=ipv4 ;;
    2) sent=ipv6 ;;
    *) warn "请输入 0 到 2。"; return 0 ;;
  esac

  case "${blocked}:${sent}" in
    ipv4:ipv4) recommended=ipv6; backup=ipv6-to-ipv4 ;;
    ipv4:ipv6) recommended=ipv6-to-ipv4; backup=ipv6 ;;
    ipv6:ipv4) recommended=ipv4-to-ipv6; backup=ipv4 ;;
    ipv6:ipv6) recommended=ipv4; backup=ipv4-to-ipv6 ;;
    *) die "内部线路组合无效。" ;;
  esac
  case "$recommended" in
    ipv4) recommended_label='IPv4→IPv4' ;;
    ipv6) recommended_label='IPv6→IPv6' ;;
    ipv4-to-ipv6) recommended_label='IPv4→IPv6' ;;
    ipv6-to-ipv4) recommended_label='IPv6→IPv4' ;;
  esac
  case "$backup" in
    ipv4) backup_label='IPv4→IPv4' ;;
    ipv6) backup_label='IPv6→IPv6' ;;
    ipv4-to-ipv6) backup_label='IPv4→IPv6' ;;
    ipv6-to-ipv4) backup_label='IPv6→IPv4' ;;
  esac
  recommended_url="$(subscription_url "$recommended" "$client")" \
    || die "无法读取推荐订阅链接。"
  backup_url="$(subscription_url "$backup" "$client")" \
    || die "无法读取备用订阅链接。"

  printf '\n推荐：%s\n' "$recommended_label"
  printf '原因：通过未被墙的入口进入 VPS，再使用未被“送中”的出口。\n'
  printf '%s\n' "$recommended_url"
  show_terminal_qr "$recommended_url"
  printf '\n备用：%s\n' "$backup_label"
  printf '说明：这个出口被“送中”，但不代表完全不可以使用。\n'
  printf '%s\n' "$backup_url"
  show_terminal_qr "$backup_url"
  printf '\n'
  read -r -p "按 Enter 返回菜单……" _ || true
}

show_route_guide() {
  clear 2>/dev/null || true
  cat <<'EOF'
什么是 IP 被墙、IP“送中”，以及如何解决？
===========================================

前提：VPS 同时拥有 IPv4 和 IPv6，并且你的网络环境支持 IPv6。

先说明一个容易误会的情况：有些网站（包括但不限于 x.com）本身不支持 IPv6。
如果你选择 IPv6 出站后无法访问这类网站，并不是 Neko 的问题，应改用 IPv4 出站。

入站：你的设备到 VPS。出站：VPS 到要访问的网站。
例如 IPv4→IPv6，代表你的设备通过 IPv4 进入 VPS，VPS 再通过 IPv6 访问网站。

检测 IP 是否被墙：可在浏览器打开 itdog.cn。检测 IPv4 时选择在线 Ping（IPv4），
检测 IPv6 时选择在线 Ping（IPv6）。如果中国大陆地区全部超时，而海外地区正常，
这个 IP 很可能被墙；如果大陆和海外都超时，也可能是 VPS 服务商迁移机房或网络故障。

IP 被墙表示对应 IPv4 或 IPv6 地址的入口被阻断，不代表另一个地址也被阻断，
也不代表一定会永久被封锁。为降低风险，可优先考虑基于 TCP 的协议，例如
VLESS + REALITY + Vision 或 AnyTLS/AnyReality，但任何协议都不能保证百分之百不被墙。

解决 IP 被墙的方法是更换入口：IPv4 被墙就使用 IPv6 入站；IPv6 被墙就使用
IPv4 入站。

检测 IP“送中”：用对应出口打开 Google，随便搜索内容并滑到页面底部。如果 Google
根据互联网地址把位置显示为中国大陆，可以认为该出口可能被“送中”。“送中”表示
Google 等服务把出口 IP 识别为中国大陆，不等于这个出口完全无法使用。视频和很多
普通网站通常仍可正常工作，但 Gemini 等部分服务可能受影响。

解决 IP“送中”的方法是更换出口：IPv4 出口被“送中”就改用 IPv6 出站；IPv6
出口被“送中”就改用 IPv4 出站。

如果 IPv4/IPv6 同时被墙或同时被“送中”，不在本功能的自动推荐范围内。

请先记住一句话：被墙换左边，送中换右边。

一、IPv4 被墙：更换入口

如果你的设备通过 IPv4 无法连接 VPS，但本地网络和 VPS 的 IPv6 都能正常使用，
可以尝试：

IPv4→IPv4
切换为
IPv6→IPv4

左边代表你的设备怎样连接 VPS。切换以后，你的设备通过 IPv6 进入 VPS，
但 VPS 仍然使用 IPv4 访问网站，因此网站兼容性基本不变。

前提是本地网络支持 IPv6、VPS 拥有可用的公网 IPv6，并且 VPS 的 IPv6 没有同时
被阻断。

二、IPv4 被“送中”：更换出口

“送中”通常是指 VPS 的 IPv4 出口被 Google 或其他网站错误识别为中国大陆，
或者因为 IPv4 的地区、信誉和风控记录而受到限制。

如果当前使用 IPv4 入站，可以把 IPv4→IPv4 切换为 IPv4→IPv6。
如果当前使用 IPv6 入站，可以把 IPv6→IPv4 切换为 IPv6→IPv6。

右边代表 VPS 使用哪个地址访问目标网站。切换以后，网站看到的是 VPS 的 IPv6，
而不是原来的 IPv4。

需要注意：IPv6 出站只能直接访问支持 IPv6 的网站，而且网站判断还可能受到账号地区、
Cookie、设备位置和自身风控政策影响，因此切换 IPv6 不能保证解决所有地区限制。

三、IPv4 入口被墙，同时 IPv4 出口又被“送中”

如果本地、VPS 和目标网站都支持 IPv6，可以尝试 IPv6→IPv6。

总结：

IPv4 入口有问题，就更换箭头左边。
IPv4 出口有问题，就更换箭头右边。

下面是完整的线路说明。

你好，很荣幸为你介绍 Neko 中入站、出站以及四种线路的区别。

如果你刚才看到一长串订阅链接，又看到 IPv4→IPv6、IPv6→IPv4 这样的名称，
感觉有点蒙，这是很正常的。

其实它们并没有看起来那么复杂。

Neko 的双栈模式只有 4 种线路方向。由于每种线路分别提供 Mihomo、Stash、
Shadowrocket 和 sing-box 四种客户端格式，所以最终会显示：

4 种线路方向 × 4 种客户端格式 = 16 条订阅链接

你不需要把 16 条链接全部导入。

只需要先找到自己正在使用的客户端，再从对应的四种线路中选择一条即可。需要测试
其他线路时，再导入相应的订阅链接。

一、什么是入站和出站？

为了方便理解，请记住：

箭头左边代表入站。
箭头右边代表出站。

入站：你的设备 → VPS
出站：VPS → 目标网站或服务

例如，你想访问一个网站：

你的设备 → VPS，这一段叫作入站。
VPS → 目标网站，这一段叫作出站。

因此，IPv6→IPv4 的完整意思是：

你的设备通过 IPv6 连接 VPS，然后 VPS 再通过 IPv4 访问目标网站。

可以把它理解为：

你的设备 → IPv6 入站 → VPS → IPv4 出站 → 目标网站

这里并不是把 IPv6“转换”成 IPv4，而是把整条连接分成前后两段，并让这两段分别
选择使用 IPv4 或 IPv6。

二、四种线路分别是什么？

IPv4→IPv4

你的设备通过 IPv4 连接 VPS，VPS 再通过 IPv4 访问网站。

这是默认推荐的线路，兼容性最好，适合绝大多数日常使用场景。

IPv6→IPv4

你的设备通过 IPv6 连接 VPS，VPS 再通过 IPv4 访问网站。

适合 IPv6 入站速度更好、IPv4 入站无法连接，或者 VPS 的 IPv4 地址被墙时使用。
由于出站仍然是 IPv4，因此网站兼容性通常较好。

IPv4→IPv6

你的设备通过 IPv4 连接 VPS，VPS 再通过 IPv6 访问网站。

适合 IPv4 入站表现更好，但希望使用 VPS 的 IPv6 地址作为出口时使用。

IPv6→IPv6

你的设备通过 IPv6 连接 VPS，VPS 再通过 IPv6 访问网站。

适合本地网络、VPS 和目标网站都能正常使用 IPv6，并且希望同时使用 IPv6 入站和
IPv6 出站的情况。

三、完全不知道怎么选怎么办？

如果你完全不知道应该选择哪一种，建议先使用：

IPv4→IPv4

这是日常使用中兼容性最好、最稳妥的默认选择。

因为目前并不是所有网站和服务都支持 IPv6。如果使用严格 IPv6 出站访问一个只支持
IPv4 的网站，访问失败属于正常现象。

四、IPv4 入站和 IPv6 入站怎么比较？

如果你想知道自己的网络使用 IPv4 入站还是 IPv6 入站更好，可以测试：

IPv4→IPv4
IPv6→IPv4

这两条线路的出站都是 IPv4，唯一的区别是你的设备通过 IPv4 还是 IPv6 连接 VPS。

请尽量在相同时间、相同网络和相同测试目标下进行比较。

哪一条延迟更低、丢包更少、连接更稳定，就选择哪一条。

如果 IPv4 入站表现更好，选择 IPv4→IPv4。
如果 IPv6 入站表现更好，选择 IPv6→IPv4。

不要直接使用 IPv4→IPv4 和 IPv6→IPv6 比较入站质量，因为这样入站和出站同时
发生了变化，测试结果不容易准确判断。

五、VPS 的 IPv4 被墙后，IPv6 为什么可能还能使用？

大家常说“VPS 的 IPv4 被墙了”，通常是指：

从受到防火墙影响的网络，通过 IPv4 无法正常连接这台 VPS。

这并不一定代表整台 VPS 已经无法使用，也不一定代表这台 VPS 的 IPv6 同时被封锁。

同一台 VPS 的 IPv4 和 IPv6 是两个不同的公网地址。

例如：

IPv4 地址：1.2.3.4
IPv6 地址：2001:db8::1

它们虽然属于同一台 VPS，但在网络中是两个不同的连接目标。因此，IPv4 地址或对应
连接被阻断时，IPv6 地址不一定也已经被阻断。

如果满足下面这些条件：

你的本地网络可以正常使用 IPv6；
VPS 拥有可以正常使用的公网 IPv6；
Neko 的 IPv6 入站正在正常工作；
VPS 的 IPv6 还没有被阻断。

那么就可以尝试：

IPv6→IPv4

此时连接过程是：

你的设备通过 IPv6 连接同一台 VPS，然后 VPS 继续通过 IPv4 访问目标网站。

也就是说，虽然原来的 IPv4 入口无法连接，但你仍然有机会通过 IPv6 入口继续使用
这台 VPS，而网站兼容性较好的 IPv4 出站仍然可以保留。

这正是 Neko 四种线路设计的重要优势之一：

IPv4 入口出现问题时，不一定需要立刻更换 VPS，也不一定需要马上重新修改传输方式
或者套用 CDN。只要 IPv6 入口仍然可用，就可以先尝试通过 IPv6→IPv4 继续使用原来
的服务器。

不过需要注意：

这并不代表 IPv6 永远不会被墙，也不代表所有封锁都能通过切换 IPv6 解决。

如果本地没有 IPv6、VPS 没有可用的公网 IPv6、IPv6 地址也被阻断，或者封锁方式
同时影响相关协议和连接特征，那么 IPv6 入站也可能无法使用。

因此，IPv6 入站更准确的定位是：

在 IPv4 入口出现问题时，为同一台 VPS 多保留一条可以尝试的入口。

六、IPv4 被“送中”后，IPv6 为什么可能正常？

大家所说的“送中”，通常是指 VPS 的出口 IP 被 Google 或其他网站错误识别为中国
大陆地区，或者因为 IP 信誉、风控数据库等原因受到限制。

这里需要注意：

网站识别的是你访问它时所使用的出口公网 IP。

如果你使用 IPv4 出站，网站看到的是 VPS 的 IPv4 地址。
如果你使用 IPv6 出站，网站看到的是 VPS 的 IPv6 地址。

同一台 VPS 的 IPv4 和 IPv6 是两个不同的公网地址。不同网站和不同 IP 数据库对这
两个地址的地理位置、用途和信誉记录可能并不相同。

因此，可能出现下面这种情况：

VPS 的 IPv4 被识别为中国大陆；
但同一台 VPS 的 IPv6 仍被识别为服务器的实际所在地区。

如果当前使用 IPv4 入站，可以尝试：

IPv4→IPv4 切换为 IPv4→IPv6

这样只更换出站，入站仍然保持 IPv4。

如果当前使用 IPv6 入站，可以尝试：

IPv6→IPv4 切换为 IPv6→IPv6

这样入站仍然保持 IPv6，只把出站从 IPv4 更换为 IPv6。

切换以后，目标网站看到的不再是原来的 IPv4 地址，而是这台 VPS 的 IPv6 地址。

如果问题确实来自 IPv4 的地理位置记录或 IP 信誉，而 IPv6 的记录正常，那么切换
IPv6 出站就可能恢复部分网站或服务的正常使用。

这也是 Neko 四种线路设计的另一个重要优势：

当 IPv4 出口的地理位置或 IP 信誉出现问题时，不需要立刻放弃整台 VPS，可以先尝试
使用同一台 VPS 的 IPv6 作为另一条出口。

你可以在 Google 浏览器中随便搜索一个内容，然后滑到页面最底部，查看 Google 显示
的位置。

如果页面明确显示该位置是“根据您的互联网地址”判断出来的，并且被识别为中国大陆，
那么说明 Google 当前可能对这个出口 IP 的位置判断有误。

不过，这个结果只能作为参考，不能作为唯一判断标准。

Gemini 或其他服务能否使用，还可能受到账号地区、浏览器记录、Cookie、设备位置和
服务自身政策等因素影响。因此，切换 IPv6 出站可能解决问题，但不能保证百分之百
有效。

另外，IPv6 出站只能直接访问支持 IPv6 的网站。如果目标网站没有提供 IPv6 服务，
那么使用严格 IPv6 出站时，该网站可能无法访问。

七、Neko 四种线路真正解决了什么？

Neko 的优势并不只是“同时支持 IPv4 和 IPv6”。

更重要的是，它把入站和出站拆开，让你可以分别选择。

入口出现问题，就更换箭头左边。
出口出现问题，就更换箭头右边。

例如：

VPS 的 IPv4 入站被墙：

IPv4→IPv4
切换为
IPv6→IPv4

这样更换的是入口，网站兼容性较好的 IPv4 出站保持不变。

VPS 的 IPv4 出站被“送中”：

IPv4→IPv4
切换为
IPv4→IPv6

这样入口保持不变，只更换网站能够看到的出口地址。

如果 IPv4 入站被墙，同时 IPv4 出站又被“送中”，并且目标网站支持 IPv6，可以
尝试：

IPv6→IPv6

这样入口和出口都会切换到 IPv6。

这就是四种线路存在的意义：

让入站和出站可以自由组合，为同一台 VPS 保留更多可以继续使用的可能。

八、最后应该怎么选？

如果你还是不知道怎么选：

默认先使用 IPv4→IPv4。

如果 IPv6 入站测试结果更好，使用 IPv6→IPv4。

如果 VPS 的 IPv4 被墙，但 IPv6 仍能连接，使用 IPv6→IPv4。

如果 IPv4 出站被错误识别地区或受到 IP 信誉限制，可以根据当前入站选择 IPv4→IPv6
或 IPv6→IPv6。

如果 IPv6 出站无法访问某些网站，请切换回 IPv4 出站。

最后记住一句话：

左边决定你怎么连接 VPS，右边决定 VPS 怎么连接网站。

IPv4 入口出现问题，就尝试更换左边。
IPv4 出口出现问题，就尝试更换右边。
EOF
  show_route_recommendation
}
