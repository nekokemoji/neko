# Neko

> 入口坏了换入口，出口有问题换出口；装完以后，还能看懂这台 VPS 到底值不值得用。

你好，欢迎使用 Neko。

你可能只是想在 VPS 上装几个节点，但 Neko 不只负责“装上协议”。它还会帮你判断
IPv4 被墙或“送中”以后有没有另一条路，以及这台 VPS 的 IP、线路和服务到底怎么样。

Neko 一次安装 Hysteria2、TUIC v5、Shadowsocks 2022、AnyTLS、AnyReality、
Trojan TLS、VLESS REALITY Vision 和 VLESS REALITY XHTTP，并为 Mihomo、Stash、
Shadowrocket、sing-box 生成订阅。

项目没有需要暴露到公网的网页面板。安装完成后，输入 `neko` 就能打开中文终端菜单。

## Neko 最值得用的地方

| 你遇到的问题 | Neko 能做什么 |
|---|---|
| VPS 的 IPv4 无法连接 | 如果本地和 VPS 的 IPv6 仍然可用，可以尝试 `IPv6→IPv4`：用 IPv6 进入原 VPS，再用兼容性更好的 IPv4 出站 |
| IPv4 被“送中”或 IP 信誉异常 | 保持入口不变，把出口切换到 IPv6，例如 `IPv4→IPv6` 或 `IPv6→IPv6` |
| 不知道 VPS 线路好不好 | 从当前真实 IPv4/IPv6 源地址测试六地区三网回程，查看 ASN 线路、平均/P95 延迟和固定 100 包丢包；目标不回应 ICMP 时自动改测 100 次 TCP 连接 |
| 想进一步检查 IP 质量和流媒体表现 | 从功能 7 直接进入 GOECS 融合怪或 NodeQuality；这些结果由对应第三方脚本生成 |
| 想让整台 VPS 临时或永久使用 AKDNS | 从功能 9 进入固定、校验且带 Neko 外层回滚的 AKDNS 3.0.0；默认不会启用 |
| 担心一键脚本装到一半 | 安装、升级、补装和凭据轮换都先检查、再验证；失败或中断时尽量恢复旧配置和服务 |

这里最重要的不是“支持 IPv6”这五个字，而是 **入站和出站可以独立选择**：

```text
你的设备 ── 入站 IPv4/IPv6 ──> VPS ── 出站 IPv4/IPv6 ──> 目标网站
```

入口出现问题，就更换箭头左边；出口地址出现问题，就更换箭头右边。

> IPv6 不是永久解封保证。使用 IPv6 入站需要本地与 VPS 都有可用 IPv6；使用严格
> IPv6 出站时，目标网站也必须支持 IPv6。

## 准备好了，开始安装

支持 Debian 12/13、Ubuntu 24.04/26.04、Rocky Linux 9/10、AlmaLinux 9/10，
架构支持 amd64 和 arm64。

开始前只需要确认三件事：

1. 这是带 systemd 的完整公网 VPS，不是普通 Docker 容器或端口映射 NAT VPS；
2. 准备一个基础域名，例如 `node.example.com`；
3. 以 root 登录，或确保系统有可用的 `sudo`。

如果域名和 DNS 已经准备好，完整复制下面的命令：

```bash
TMP="$(mktemp)" && \
curl -fsSL --retry 4 https://raw.githubusercontent.com/nekokemoji/neko/main/bootstrap.sh -o "$TMP" && \
bash "$TMP"
```

这条入口命令本身需要系统已有 `curl` 和 `mktemp`；进入 Bootstrap 后，`tar`、`gzip`
等精简系统可能缺少的首次安装工具会自动补齐。

Bootstrap 会下载固定的 Neko 1.13.1 源码版本；核心程序也固定版本并校验对应架构的
SHA-256，不会在安装时临时解析不确定的 `latest`。

还没有配置 DNS？先不要急，继续看下面的“第一次使用，照着做就行”。

---

## 第一部分：第一次使用，照着做就行

### 1. 选择安装哪种网络

安装器一开始会询问：

```text
1. 只安装严格 IPv4
2. 只安装严格 IPv6
3. 同时安装严格 IPv4 与 IPv6
```

| VPS 情况 | 建议选择 | 安装结果 |
|---|---|---|
| 只有公网 IPv4 | 1 | 4 条严格 IPv4 订阅 |
| 只有公网 IPv6 | 2 | 4 条严格 IPv6 订阅 |
| IPv4、IPv6 都正常 | 3 | 四个线路方向各 4 条，共 16 条 |
| 两种地址都有，但暂时只想用一种 | 先装需要的一种 | 以后可从面板补装另一种 |

脚本不会把不存在的 IPv6“变出来”，也不会为了显示安装成功，把 IPv6 节点偷偷改成
IPv4。所选地址必须真实属于 VPS 网卡，并且拥有对应默认路由。

### 2. 配置域名与 DNS

安装时请输入**基础域名**：

```text
node.example.com
```

不要输入 `v4.node.example.com` 或 `v6.node.example.com`。Neko 会自动使用 `v4.`、
`v6.` 专用域名来验证和固定地址族。

假设 VPS 地址为 `VPS_IPv4` 和 `VPS_IPv6`：

| 安装方式 | 需要创建的记录 | 必须删除 |
|---|---|---|
| 只装 IPv4 | `node`：A；`v4.node`：同一条 A | 这两个名称的 AAAA 和 CNAME |
| 只装 IPv6 | `node`：AAAA；`v6.node`：同一条 AAAA | 这两个名称的 A 和 CNAME |
| IPv4 + IPv6 | `node`：A + AAAA；`v4.node`：A；`v6.node`：AAAA | `v4.node` 的 AAAA/CNAME；`v6.node` 的 A/CNAME |

以 Cloudflare 为例，所有记录都必须是 **仅 DNS（灰色云朵）**，不能打开橙色代理。
每个专用域名只能保留一条对应地址族记录。

要求严格是为了保证：`v4.` 只把客户端送到 VPS 的 IPv4，`v6.` 只送到 IPv6。
CNAME、橙云或多余记录都会改变真实入口，安装器会拒绝继续。

单栈安装不需要提前创建未启用的那一族。例如只装 IPv4 时，不需要创建 `v6.node`；
以后补装 IPv6 前再创建即可。

### 3. 选择证书方式

默认推荐 **Cloudflare DNS-01**：Let’s Encrypt 不需要从公网连接 VPS 的 TCP 80，
更适合单栈、IPv6 入站不稳定或云安全组较复杂的 VPS。

Cloudflare Token 只需要：

- `Zone / Zone / Read`
- `Zone / DNS / Edit`
- Zone Resources 只包含本项目使用的域名

不要使用 Global API Key。粘贴 Token 时终端不显示字符是正常的，直接按回车即可。

不使用 Cloudflare 也可以选择 **HTTP-01**，但基础域名和所有已启用专用域名都必须能
通过公网 TCP 80 访问当前 VPS；双栈时 IPv4、IPv6 验证都必须成功。

<details>
<summary>证书方式的安全与失败处理</summary>

Cloudflare Token 保存为 root-only 文件：凭据目录权限为 `0700`，文件权限为 `0600`。
它不会写进订阅、命令行或普通日志，续期也会沿用安装时选择的验证方式。

HTTP-01 只在验证时临时开放本机 TCP 80；firewalld 临时规则带超时保护，并会在成功、
失败或正常中断时清理。

证书申请与续期有总时限。Let’s Encrypt 返回 `rateLimited` 时，脚本会显示可解析到的
恢复时间并停止，不会反复申请、自动更换域名或偷偷切换验证方式。

</details>

### 4. 运行安装

回到上面的安装命令，按提示完成：

1. 选择网络类型；
2. 输入基础域名；
3. 输入 ACME 邮箱；
4. 选择证书方式；
5. DNS-01 模式下粘贴 Cloudflare Token；
6. 核对摘要并输入 `y`。

安装器会检查 DNS、地址归属、默认路由、端口、证书和程序哈希，生成配置后再用冻结的
sing-box、Xray 与 Caddy 真实校验。关键步骤失败时会停止，不会带着半套配置假装成功。

高级用户的非交互安装参数见后面的“专业用户”部分。

### 5. 放行云安全组

安装结束时会显示这台 VPS 实际使用的随机端口。请在云厂商控制台放行精确列表：

| 类型 | 端口 |
|---|---|
| TCP | 443、SS2022、AnyTLS、AnyReality、Trojan、Vision、XHTTP；双栈还包括跨族第二组端口 |
| UDP | Hysteria2 的完整 128 端口区间、TUIC、SS2022；双栈还包括跨族第二组区间/端口 |
| TCP 80 | 只有 HTTP-01 必须公网放行 |
| TCP 8443 | **不要公网放行**，它只监听 `127.0.0.1` |

Neko 会管理正在使用的 firewalld 或 UFW 中属于自己的规则，但无法替你修改云厂商网页
里的安全组。

### 6. 导入订阅

输入：

```bash
sudo neko
```

选择 `1` 查看订阅链接和二维码。

| 客户端 | 订阅格式 | 每个线路方向的节点数 |
|---|---|---:|
| Mihomo | YAML | 7 |
| Stash | YAML | 6 |
| Shadowrocket | Base64 文本订阅 | 8 |
| sing-box | 官方 Remote Profile JSON | 7 |

如果双栈模式出现 16 条链接，不要慌：

```text
4 个线路方向 × 4 种客户端格式 = 16 条订阅链接
```

先找到自己使用的客户端，再选择一个线路方向即可。通常只需要导入一条；想比较线路时
再导入其他方向。

二维码在 VPS 本地生成，不调用在线二维码网站。二维码和完整订阅链接都相当于密码，
不要公开分享。qrc 下载或终端显示失败时，文字链接仍然可用，代理服务不会受影响。

各客户端只接收已经验证兼容的节点：AnyReality 只加入 Shadowrocket 和 sing-box，
XHTTP 只加入 Mihomo 和 Shadowrocket。因此 Mihomo 为 7 个、Stash 为 6 个、
Shadowrocket 为 8 个、sing-box 为 7 个；这不是订阅生成遗漏。

### 7. 四种线路怎么选

也可以随时在 `neko` 面板选择 `8` 查看这段说明。

箭头左边是入站，箭头右边是出站：

```text
IPv6→IPv4 = 你的设备通过 IPv6 连接 VPS，再由 VPS 通过 IPv4 访问网站
```

| 线路 | 适合什么时候使用 |
|---|---|
| `IPv4→IPv4` | 默认推荐，兼容性最好，适合绝大多数日常使用 |
| `IPv6→IPv4` | IPv6 入站更好，或者 VPS 的 IPv4 入口被墙、IPv6 仍能连接 |
| `IPv4→IPv6` | IPv4 入站正常，但希望换成 IPv6 出口地址 |
| `IPv6→IPv6` | 入站和出站都希望使用 IPv6，且目标网站支持 IPv6 |

#### IPv4 被墙：尝试更换入口

“VPS 的 IPv4 被墙”通常是指通过 IPv4 无法正常连接这个地址，并不一定代表整台 VPS
或它的 IPv6 同时失效。

如果本地与 VPS 都有可用 IPv6，可以尝试：

```text
IPv4→IPv4  改为  IPv6→IPv4
```

这样只更换入口，VPS 访问网站时仍使用兼容性更好的 IPv4。很多情况下可以先继续使用
原来的服务器，不必立刻换 VPS 或增加 CDN。

它不是永久保证：本地没有 IPv6、VPS IPv6 不可达、IPv6 也被阻断，或者相关连接特征
同时受到影响时，这条线路仍可能失败。

#### IPv4 被“送中”：尝试更换出口

网站看到的是出站公网 IP。同一台 VPS 的 IPv4 和 IPv6 是两个不同地址，地理位置库和
风险数据库对它们的记录可能不同。

如果 IPv4 出口被错误识别，可以保持当前入口，只更换右边：

```text
IPv4→IPv4  改为  IPv4→IPv6
IPv6→IPv4  改为  IPv6→IPv6
```

切换后，目标网站看到的是 VPS 的 IPv6。它可能改善由 IPv4 地理位置或信誉记录造成的
限制，但不能保证解决所有问题；账号地区、Cookie、设备位置和服务政策也可能参与判断。

Google 搜索页面底部的位置可以作为参考。如果它明确写着“根据您的互联网地址”，说明
该结果可能与出口 IP 有关，但仍不能把它当作唯一证据。

严格 IPv6 出站只能访问支持 IPv6 的目标。遇到只有 IPv4 的网站时，请改用右边为 IPv4
的线路。

#### 怎样公平比较线路

- 比较入站：测试 `IPv4→IPv4` 和 `IPv6→IPv4`，保持右边相同；
- 比较出站：测试 `IPv4→IPv4` 和 `IPv4→IPv6`，保持左边相同；
- 尽量在相同时间、相同本地网络和相同目标下比较延迟与稳定性。

一句话记住：**左边决定怎么连接 VPS，右边决定 VPS 怎么连接网站。**

### 8. 使用 VPS 体检

在 `neko` 面板选择 `7`：

```text
1. GOECS 融合怪（固定入口，执行前确认）
2. NodeQuality 综合测试（固定入口，执行前确认）
3. Neko 三网线路检测
0. 返回
```

前两项只下载 `versions.env` 固定提交的入口脚本并校验 SHA-256。校验后会显示精确来源、
提交、哈希及传递下载边界；直接按 Enter 会取消，只有分别输入 `RUN-GOECS` 或
`RUN-NODEQUALITY` 才会以 root 运行。固定入口不等于固定完整执行链：GOECS 仍会查询
`releases/latest` 并下载二进制，NodeQuality 仍会从 `main`、Check.Place 等地址加载
组件；这些传递内容不由 Neko 校验。
第三项是 Neko 自带的精简六地三网回程检测。地区菜单中 `1`–`6` 依次为广东、上海、
北京、四川、湖北、辽宁，`7` 才是全部地区；输出 ASN 线路、平均/P95 延迟与丢包。
每个目标固定发送 100 个 ICMP 包；目标不回应 ICMP 时改测 100 次 TCP 连接成功率。
运行前会显示预计耗时，并要求输入 `ROUTE`，但不会修改 Neko 或系统配置。

### 9. 可选使用 AKDNS 智能 DNS 解锁

在 `neko` 面板选择 `9`。这个功能默认关闭，并且不会在安装或升级时自动改变 DNS。

Neko 不复制或修改 AKDNS 源码，而是在每次打开时只下载 AKDNS 3.0.0 的固定上游提交
`d9a3f7caa08f528d55d799d73d37394026326a4d`，核对固定 SHA-256 后才执行。`main` 分支
后来发生变化不会静默进入已安装机器。

AKDNS 是**整台 VPS 的系统 DNS 接管**，不是只影响 sing-box、Xray 或某一条订阅。
永久启用前，Neko 会额外保存以下精确状态：

- `/etc/resolv.conf` 的文件/符号链接类型、内容、权限和 immutable 状态；
- `/etc/nsswitch.conf`、AKDNS 可能生成的备份和 NetworkManager 接管文件；
- `systemd-resolved` 与 `resolvconf` 的 active/enabled 状态。

上游脚本返回后，Neko 会把两类检查分开：固定官方 AKDNS 必须能通过 UDP 或 TCP 正常
递归解析公共域名；Neko 自己的严格 `v4.`/`v6.` A/AAAA 则通过中立公共 DNS 核验，避免
智能 DNS 对自定义域名返回 `NXDOMAIN / EDE 17 (Filtered)` 时产生假失败。随后会重新
生成并校验客户端订阅、sing-box/Xray/Caddy 配置，并重启确认四个 Neko 服务。下载失败、
脚本异常退出、未知 DNS、递归健康失败、配置/服务失败或终端中断，都会同时恢复系统 DNS、
AKDNS 管理状态和操作前的订阅文件。功能 9 的“紧急恢复”不依赖 AKDNS 自己的备份菜单。

AKDNS 3.0.0 当前提供的是 IPv4 DNS 服务器。它可以回答 A 和 AAAA，但 VPS 本身仍必须
能连接 IPv4 DNS/53；没有 IPv4 出站的严格 IPv6-only VPS 不适合启用。云厂商、上游
防火墙或安全策略还需要允许到所选 AKDNS 地址的 UDP/TCP 53。

启用成功后，Neko 会让 **IPv4 出口**的 sing-box、Mihomo 和 Stash 订阅把 DNS 请求
放进代理隧道，再由该 VPS 以 TCP/53 查询当前 AKDNS；这才会让控制台给本机公网 IPv4
选择的服务节点实际参与 YouTube 等域名解析。IPv6 出口仍使用严格公共 IPv6 DoH，因为
AKDNS 当前没有 IPv6 解析器地址。服务端也按出口隔离解析：IPv4 出口继续继承系统
AKDNS，IPv6 出口固定通过 IPv6 DoH 查询 AAAA，不会因 AKDNS 对目标返回空 AAAA 而失效。
这只能恢复目标真实 IPv6，不能让 IPv6 出口获得 AKDNS 控制台选择的 IPv4 解锁地区。
需要重新导入或更新一次订阅，旧客户端配置不会自动改变。
Shadowrocket 的节点订阅格式不能可靠覆盖应用的全局 DNS 设置；使用它时应在 Shadowrocket
中把远程 DNS 手动设为当前 AKDNS，并开启“通过代理/遵循代理”后清除 DNS 与浏览器缓存。
服务端会在目标仅以 IP 传入时恢复常见 HTTP Host 与 TLS/QUIC SNI，再按出口地址族解析；
sing-box 与 Hysteria 把新增恢复范围限制在 HTTP/HTTPS 常用端口，Xray 继续使用原有入站
嗅探。这样可避免把客户端拿到的 IPv4 AKDNS 结果直接塞进严格 IPv6 出口。
账号地区、Cookie、设备定位以及网站按出口 IP 判定仍可能影响页面地区，DNS 解锁不能改变
VPS 自身公网 IP 的注册国家。

> AKDNS 菜单中的“流媒体解锁检测”会再运行由 AKDNS 上游选择的另一份第三方脚本；
> 那份检测脚本不属于 Neko 的固定源码与 SHA-256 边界。只需要设置 DNS 时不要选择它。
> 需要还原时应退出 AKDNS 上游界面，回到 Neko 功能 9 选择“紧急恢复”，不要使用上游
> 的备份编号恢复，以确保使用的是 Neko 在本次接管前保存的精确快照。

### 10. 终端面板能做什么

| 选项 | 功能 | 常见用途 |
|---:|---|---|
| 1 | 查看订阅链接和二维码 | 新设备导入、比较四种线路 |
| 2 | 开启 BBRv1 | 使用系统自带 BBR，不安装第三方内核 |
| 3 | 订阅与节点访问管理 | 分别轮换订阅 URL、节点凭据，或紧急全部换新 |
| 4 | 刷新已安装地址族端点 | VPS 公网 IP 变化后，安全更新绑定地址 |
| 5 | IPv4/IPv6 安装管理 | 单栈安装以后补装缺少的地址族 |
| 6 | 卸载全部协议 | 删除 Neko 服务、数据和自己创建的防火墙规则 |
| 7 | 第三方 VPS 体检 & Neko 自带体检 | 第三方综合测试或六地三网线路检测 |
| 8 | 双栈线路怎么选？（同时拥有 IPv4 和 IPv6 时查看） | 阅读说明后按被墙入口和“送中”出口生成推荐/备用链接与二维码 |
| 9 | AKDNS 智能 DNS 解锁（第三方、可选） | 打开固定上游脚本、紧急恢复或查看当前接管状态 |

订阅 URL 与节点凭据分开管理：

| 操作 | 旧订阅 URL | 已导入的旧节点 | 什么时候用 |
|---|---|---|---|
| 重置订阅 URL | 失效 | 继续可用 | 只怀疑链接被看到 |
| 重置全部节点凭据 | 不变 | 全部失效 | 撤销旧设备，但保留订阅地址 |
| 紧急全部换新 | 失效 | 全部失效 | 链接和节点都可能泄露 |

这些操作都会先备份和校验。服务启动失败或操作意外中断时会恢复旧状态；只有恢复本身
也失败，才会保留 root-only 备份并要求停止后续操作。

---

## 第二部分：给专业用户看的实现、边界与验证

### 项目定位

Neko 把三类工作放在同一套有状态流程里：

1. 部署八种互补协议，并输出四类客户端订阅；
2. 用端到端规则实现四方向严格 IPv4/IPv6；
3. 从面板进入第三方体检或 Neko 六地三网线路检测。

它不是大型跑分脚本的替代品，也不是多用户商业面板。关键配置使用冻结核心验证，
维护操作尽量保持可回滚；第三方体检的行为与数据处理由对应上游项目负责。

### 协议与订阅矩阵

| 协议 | 服务端核心 | 传输 | Mihomo | Stash | Shadowrocket | sing-box |
|---|---|---|:---:|:---:|:---:|:---:|
| Hysteria2 | Hysteria | UDP + 128 端口跳跃 | ✓ | ✓ | ✓ | ✓ |
| TUIC v5 | sing-box | UDP | ✓ | ✓ | ✓ | ✓ |
| Shadowsocks 2022 | sing-box | TCP + UDP | ✓ | ✓ | ✓ | ✓ |
| AnyTLS | sing-box | TCP + TLS | ✓ | ✓ | ✓ | ✓ |
| Trojan TLS | sing-box | TCP + TLS | ✓ | ✓ | ✓ | ✓ |
| VLESS REALITY Vision | Xray | TCP/RAW | ✓ | ✓ | ✓ | ✓ |
| VLESS REALITY XHTTP | Xray | TCP/XHTTP | ✓ | — | ✓ | — |
| AnyReality | sing-box | TCP/AnyTLS + REALITY | — | — | ✓ | ✓ |

sing-box 输出的是可直接添加为 Remote Profile 的完整官方 JSON，包含 TUN、DNS、路由、
选择器和七个代理出站，不是节点列表或在线转换接口，并由冻结的 sing-box 真实执行
`check`。

TUIC、Trojan 等节点即使使用 IP 字面量作为服务器，也保留基础域名 SNI 并正常验证
证书，不开启 `skip-cert-verify`。Trojan 使用独立随机端口，不与订阅网站共用 TCP 443。

### 四方向严格模式

| 线路 | 节点入口与监听 | 目标解析与异族拒绝 | 服务端出口 |
|---|---|---|---|
| IPv4→IPv4 | VPS IPv4 / 精确 IPv4 监听 | 只取 IPv4，拒绝 IPv6 | 绑定 IPv4 源地址 |
| IPv6→IPv6 | VPS IPv6 / 精确 IPv6 监听 | 只取 IPv6，拒绝 IPv4 | 绑定 IPv6 源地址 |
| IPv4→IPv6 | VPS IPv4 / 精确 IPv4 监听 | 只取 IPv6，拒绝 IPv4 | 绑定 IPv6 源地址 |
| IPv6→IPv4 | VPS IPv6 / 精确 IPv6 监听 | 只取 IPv4，拒绝 IPv6 | 绑定 IPv4 源地址 |

具体约束包括：

- Mihomo 写入 `ip-version: ipv4` / `ipv6`；
- sing-box Remote Profile 只使用所选族 DNS，拒绝另一族，并且没有 DIRECT 回退出站；
- sing-box 服务端设置同族解析策略、异族拒绝与 `inet4_bind_address` / `inet6_bind_address`；
- Xray 为四个方向生成独立入站，并使用精确 `listen`、`sendThrough` 与 `ForceIPv4` / `ForceIPv6`；
- Hysteria 双栈生成四份配置，使用对应 `mode` 与 `bindIPv4` / `bindIPv6`；
- IPv4 服务端出口继续使用系统解析器，IPv6 服务端出口使用独立 IPv6 DoH，避免系统
  AKDNS 的 IPv4 解锁回答干扰严格 IPv6；
- sing-box 与 Hysteria 只在 TCP 80/443、UDP 443 恢复 HTTP Host、TLS/QUIC SNI；
  Xray 沿用已有入站嗅探，三个核心随后都按出口地址族解析，不把严格 IPv6 静默回落到 IPv4；
- 四个 Hysteria 子进程作为一组监管，任一退出时停止其余进程，再由 systemd 重启整组。

入口或出口不可用时都会明确失败，不会自动换成另一族。只绑定出站源地址不足以阻止
目标中的异族 IP 字面量，因此显式异族拒绝是必要边界。

Neko 能控制自己生成的配置和 VPS 端行为，但不能控制运营商 DNS64/NAT64、系统级
VPN、透明代理或客户端私自改写。

### 安全默认值与事务维护

三套代理核心默认拒绝客户端访问：

- 私有、回环、链路本地和云元数据等非公网地址；
- TCP 25。

这降低了订阅被导入不可信设备后扫描 VPS 内网或滥发 SMTP 的风险。

安装、升级、补装地址族、刷新端点、重置订阅 URL、轮换节点凭据和紧急全部换新都会：

1. 获取维护锁并检查状态；
2. 备份状态、配置、证书、服务和 Neko 自己的防火墙规则；
3. 原子写入新状态并重新渲染；
4. 用冻结核心检查配置；
5. 重启服务并确认持续运行；
6. 失败或正常中断时恢复旧状态。

firewalld 规则只添加到对应默认路由网卡所属 zone；UFW 使用独立 `NekoProxy` 应用规则。
未知的自定义 nftables/iptables 不会被擅自改写，卸载也只清理 Neko 创建的规则。

### 参数安装与完全非交互

下面的参数形式仍会询问证书方式并要求最终确认：

```bash
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --network-mode dual
```

`--network-mode` 可取 `ipv4-only`、`ipv6-only` 或 `dual`。

完全非交互的 Cloudflare DNS-01 安装需要 `--yes`，并应使用 root-only Token 文件，
不要把 Token 放进命令行参数：

```bash
sudo install -m 0600 /path/to/token-file /root/neko-cloudflare-token
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --network-mode dual \
  --acme-method cloudflare-dns-01 \
  --cloudflare-token-file /root/neko-cloudflare-token \
  --yes
```

HTTP-01 可改用 `--acme-method http-01`。`--yes` 只跳过最终确认，不会跳过 DNS、地址、
路由、端口、哈希、配置或证书检查。

### 固定版本与测试证据

当前 Neko 版本为 **1.13.1**。`versions.env` 固定 Xray、sing-box、Hysteria、Caddy、
lego、Mihomo、qrc 和 NextTrace Tiny 的版本与 amd64/arm64 SHA-256；可选 AKDNS 还固定
上游提交与脚本 SHA-256。GOECS 与 NodeQuality 也固定入口提交和 SHA-256，但因为上游
入口会继续下载可变组件，仍必须在面板中阅读边界并输入专用确认词。

本地完整测试：

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

测试覆盖三种安装模式、4/4/16 份订阅、四方向真实核心解析、严格 DNS 与异族拒绝、
Cloudflare DNS-01、HTTP-01、证书扩展、令牌与凭据轮换、端点刷新、补装、升级迁移、
二维码解码、第三方体检固定入口/哈希/确认、六地三网线路、默认 AnyReality、AKDNS
系统文件事务以及失败回滚。

GitHub Actions 的发行版用户空间矩阵覆盖 Debian 12/13、Ubuntu 24.04/26.04、Rocky
Linux 9/10、AlmaLinux 9/10 的 amd64 与 arm64，共 16 个组合。专用 VM 工作流还会在
8 个官方 amd64 云镜像的完整 QEMU/systemd 环境中运行四线路渲染、AKDNS 隔离事务、
ACME 保护和 unit 解析/启动。

完整 VM 仍不能替代真实公网 DNS、ACME、云安全组和移动客户端。自动化已经验证什么、
仍需真实 VPS 验证什么，请看 [TESTING.md](TESTING.md)。

### VPS 体检边界

功能 7 包含三项：GOECS 官方入口、NodeQuality 官方入口，以及 Neko 自带的精简六地
三网线路检测。Neko 不再提供旧版完整自研体检，也不会替第三方脚本解析或过滤结果。
Neko 固定并校验两份入口脚本，但它们内部仍下载未由 Neko 固定的组件；因此默认不执行，
必须输入界面显示的专用确认词。第三方脚本可能安装依赖、修改系统、发起公网请求、执行
性能测试或上传结果；具体数据源、隐私和资源消耗以对应上游项目说明为准。Neko 自带部分
只做回程 ASN、延迟和丢包/连接成功率检测，不做硬件跑分、流媒体解锁或完整 IP 质量判断。

## 升级

已经安装 Neko 时，可直接复制下面整段命令。它会从 GitHub `main` 获取最新源码、运行
升级脚本并自动清理临时文件：

```bash
(
  set -Eeuo pipefail
  NEKO_UPGRADE_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$NEKO_UPGRADE_DIR"' EXIT
  curl -fsSL --retry 4 \
    https://github.com/nekokemoji/neko/archive/refs/heads/main.tar.gz \
    -o "$NEKO_UPGRADE_DIR/neko.tar.gz"
  mkdir "$NEKO_UPGRADE_DIR/source"
  tar -xzf "$NEKO_UPGRADE_DIR/neko.tar.gz" \
    --strip-components=1 -C "$NEKO_UPGRADE_DIR/source"
  if [ "$(id -u)" -eq 0 ]; then
    bash "$NEKO_UPGRADE_DIR/source/upgrade.sh"
  else
    sudo bash "$NEKO_UPGRADE_DIR/source/upgrade.sh"
  fi
)
```

如果已经位于最新源码目录，也可以直接执行：

```bash
sudo bash upgrade.sh
```

升级会保留端口、协议凭据、REALITY 参数、订阅令牌、旧 URL 和证书方式。升级前会备份
状态、配置、程序、systemd 单元和证书；核心校验、证书或服务启动失败时自动回滚。

证书续期由 `neko-renew.timer` 每天检查一次并随机延迟：

```bash
systemctl status neko-renew.timer
journalctl -u neko-renew.service --since '7 days ago'
```

每次续期会先在 root-only 目录快照完整 lego 状态，再校验证书/私钥配对、严格 SAN、
有效期、全部服务端配置和应有的 sing-box 订阅。证书变化后，四个核心按固定顺序逐个
重启并通过健康检查才会提交；任一步失败会恢复原证书、权限和服务 active 状态。若自动
恢复本身失败，日志会保留并显示可人工恢复的快照路径。

## 常见问题

| 现象 | 通常原因 | 怎么处理 |
|---|---|---|
| 专用域名存在多余 A/AAAA | 记录建错、输入了专用域名或 DNS 缓存未更新 | 输入基础域名；删除异族记录和 CNAME |
| DNS 出现 Cloudflare 的 `13.*`、`76.*` 等地址 | 打开了橙云代理 | 改为“仅 DNS”并等待公共 DNS 更新 |
| HTTP-01 的 IPv6 显示 `Network unreachable` | IPv6 入站、路由或安全组不可达 | 修复网络，或使用 DNS-01 |
| Let’s Encrypt 返回 429 / `rateLimited` | 相同域名组合短时间签发过多 | 等待脚本显示的 UTC 恢复时间，不要反复重装 |
| 严格 IPv6 无法打开只有 A 记录的网站 | 目标不支持 IPv6，属于正常严格行为 | 改用右边为 IPv4 的订阅 |
| sing-box Remote Profile 导入失败 | 链接不完整，或所用应用不支持当前官方配置格式 | 重新复制完整链接，并优先使用近期版本的 sing-box 内核客户端 |
| 二维码没有显示 | qrc 下载、终端宽度或环境不满足 | 直接复制文字链接，代理服务不受影响 |
| 第三方体检下载/校验失败 | 固定 GitHub Raw 入口不可达，或内容与固定 SHA-256 不同 | 不要绕过校验；稍后重试或等待 Neko 更新固定提交，代理服务不受影响 |
| AKDNS 自动恢复 | 固定脚本下载/校验失败、DNS 不在官方列表、公共递归不健康，或订阅/服务验证失败 | 查看上方具体错误；原 DNS 与订阅已恢复时可继续用 Neko，勿反复强制修改 `/etc/resolv.conf` |

安全检查命令：

```bash
systemctl is-active neko-caddy neko-sing-box neko-xray neko-hysteria
systemctl --no-pager --full status neko-sing-box neko-xray neko-hysteria
journalctl -u neko-sing-box -u neko-xray -u neko-hysteria -n 100 --no-pager
ip -4 route show default
ip -6 route show default
```

请不要公开 Cloudflare Token、完整订阅 URL、完整 `/etc/neko/state.json`、证书私钥、
SSH 密码或 SSH 私钥。

<details>
<summary>上游官方资料与诊断数据源</summary>

- [Cloudflare DNS-only](https://developers.cloudflare.com/dns/proxy-status/) 与 [API Token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Let’s Encrypt Challenge Types](https://letsencrypt.org/docs/challenge-types/)
- [sing-box 配置与 Remote Profile](https://sing-box.sagernet.org/)
- [Hysteria2 服务端配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/) 与 [端口跳跃](https://v2.hysteria.network/docs/advanced/Port-Hopping/)
- [Xray REALITY](https://xtls.github.io/en/config/transports/reality.html)、[XHTTP](https://xtls.github.io/en/config/transports/xhttp.html) 与 [出站策略](https://xtls.github.io/en/config/outbound.html)
- [Caddy TLS](https://caddyserver.com/docs/caddyfile/directives/tls)
- [AKDNS 固定上游提交](https://github.com/akile-network/aktools/blob/d9a3f7caa08f528d55d799d73d37394026326a4d/akdns.sh)
- [GOECS](https://github.com/oneclickvirt/ecs) 与 [NodeQuality](https://github.com/LloydAsp/NodeQuality)

</details>

## 使用边界

请只在你有权管理的服务器和网络中使用，并遵守所在地法律、服务商条款和组织政策。

严格地址族、证书验证、默认内网阻断和 TCP 25 拒绝都是项目的安全边界，不会为了
“看起来什么都能访问”而默认放宽。

如果系统、客户端或网络环境与文档不一致，欢迎提供去除敏感信息后的系统版本、错误行
和服务日志。项目会持续维护，但每一次修复仍以可复现、可测试和可回滚为前提。

## 致谢

感谢 X 用户 `@qian67068` 协助测试 Stash 兼容性。
