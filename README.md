# Neko 多协议部署脚本

Neko 是面向独立公网 VPS 的终端部署工具。它安装 Hysteria2、TUIC v5、Shadowsocks 2022、AnyTLS、VLESS REALITY Vision 和 VLESS REALITY XHTTP，并可选择只安装严格 IPv4、只安装严格 IPv6，或同时安装两者。Mihomo、Stash、Shadowrocket、sing-box 会为每个已安装地址族各生成一份订阅。

本项目没有网页面板。安装后使用 `neko` 打开终端菜单。请只在你有权管理的服务器和网络中使用，并遵守所在地法律、服务商条款与组织政策。

## 先说清楚：为什么是 4 条或 8 条订阅

每个已安装地址族对应 4 条链接。单栈安装共 4 条，双栈安装共 8 条：

| 客户端 | 严格 IPv4 | 严格 IPv6 | 节点数 |
|---|---|---|---:|
| Mihomo | `https://v4.<域名>/<IPv4令牌>/mihomo.yaml` | `https://v6.<域名>/<IPv6令牌>/mihomo.yaml` | 6 / 6 |
| Stash | `https://v4.<域名>/<IPv4令牌>/stash.yaml` | `https://v6.<域名>/<IPv6令牌>/stash.yaml` | 5 / 5 |
| Shadowrocket | `https://v4.<域名>/<IPv4令牌>/shadowrocket.txt` | `https://v6.<域名>/<IPv6令牌>/shadowrocket.txt` | 6 / 6 |
| sing-box | `https://v4.<域名>/<IPv4令牌>/sing-box.json` | `https://v6.<域名>/<IPv6令牌>/sing-box.json` | 5 / 5 |

IPv4 与 IPv6 使用相互独立的下载令牌，可以只重置其中一族。这里没有“自动版”，也没有 IPv4 优先后回退 IPv6。严格约束覆盖完整链路：

- IPv4 下载域名只有 A，没有 AAAA；IPv6 下载域名只有 AAAA，没有 A。
- 所有已生成配置中的节点 `server` 都是对应族的 IP 字面量，客户端不再对节点域名做双栈选择。
- Mihomo 另外写入 `ip-version: ipv4` 或 `ip-version: ipv6`。
- sing-box 使用完整的官方 Remote Profile JSON：TUN 捕获双栈流量，DNS 只解析所选地址族，路由明确拒绝另一地址族，且没有 DIRECT 出站或自动回退。
- TLS SNI、证书主机名、REALITY `serverName` 和 XHTTP Host 始终保留基础域名。
- 服务端只为已安装地址族创建监听，并把来自该入口的流量路由到同族直连出口；sing-box 在路由阶段只解析同族地址、拒绝异族 IP 字面量并绑定同族源地址，Xray 使用 `ForceIPv4`/`ForceIPv6` 和源地址绑定，Hysteria 为每个已安装地址族使用独立的 `mode: 4`/`mode: 6` 实例。
- 对应地址族不可用时直接失败，不会由生成配置或 VPS 出站回退到另一族。例如只有 A、没有 AAAA 的目标通过严格 IPv6 订阅应访问失败。

脚本能约束 DNS 记录和生成的客户端配置，但不能控制客户端之外的网络。运营商 DNS64/NAT64、系统级 VPN、透明代理或客户端自身改写仍可能改变实际链路；任何服务端脚本都无法绕过这一边界。

## 必须先配置的 DNS

假设基础域名是 `node.example.com`，VPS 地址为 `VPS_IPv4` 与 `VPS_IPv6`：

| 安装模式 | 基础域名 | 专用订阅域名 | 不允许 |
|---|---|---|---|
| 只装 IPv4 | `node`：1 条 A | `v4.node`：同一条 A | `node` 的 AAAA；`v4.node` 的 AAAA/CNAME |
| 只装 IPv6 | `node`：1 条 AAAA | `v6.node`：同一条 AAAA | `node` 的 A；`v6.node` 的 A/CNAME |
| IPv4 + IPv6 | `node`：1 条 A + 1 条 AAAA | `v4.node`：同一条 A；`v6.node`：同一条 AAAA | 两个专用名称的异族记录或 CNAME |

单栈安装不要求创建尚未启用的专用域名；以后从控制面板补装另一族时再创建即可。所有已启用记录都必须直接指向本机公网地址，不能使用 CNAME、CDN 或代理。使用 Cloudflare 时必须保持 [DNS-only（灰云）](https://developers.cloudflare.com/dns/proxy-status/)，因为橙云返回的是 Cloudflare Anycast 地址而不是源站地址。

安装器会硬性检查：

- 每个已启用专用域名恰好有 1 条对应族的直连记录，且没有异族记录或 CNAME；
- 基础域名只包含所选地址族，并与对应专用域名完全一致；
- 所选 A/AAAA 地址确实配置在本机网卡上，可用于服务监听和出站源地址绑定；
- 每个所选地址族都有默认路由；选择 IPv6 时内核必须启用 IPv6；
- TCP 80、443、8443 未被其他程序占用；
- Let’s Encrypt 为基础域名和所有已启用专用域名成功签发同一张 SAN 证书。

## 证书验证方式

交互安装默认推荐 **Cloudflare DNS-01**。安装器通过 Cloudflare API 临时创建并清理 `_acme-challenge` TXT 记录，因此证书验证不依赖 VPS 的 IPv6 入站路由，也不要求公网放行 TCP 80。A/AAAA 仍须按上表保持 DNS only，因为它们同时用于订阅下载和严格地址校验。

先在 Cloudflare 创建一个专用 API Token，只授予以下权限，并把 Zone Resources 限定为这个域名所在的单个 zone：

- `Zone / Zone / Read`
- `Zone / DNS / Edit`

不要使用 Global API Key，也不要授予账户级无关权限。lego 的 [Cloudflare provider 文档](https://go-acme.github.io/lego/dns/cloudflare/)明确说明同一个 Token 可以同时承担这两项权限。Cloudflare 的[创建 Token 文档](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)说明了控制台入口、资源范围和只显示一次的密钥。

安装时直接在隐藏输入提示中粘贴 Token；屏幕不会回显。Token 不会写入命令行、日志或 `state.json`，只会保存到：

```text
/var/lib/neko/credentials/cloudflare-dns-api-token
```

该目录和文件分别强制为 root 所有的 `0700`、`0600`，供自动续期使用。

也可在安装菜单中选择 HTTP-01 兼容模式。HTTP-01 不需要 Token，但 Let’s Encrypt 只能通过 TCP 80 验证；基础域名和所有已启用专用域名的公网验证视角都必须能连到本机。两种模式不会同时运行，也不会自动互相回退。官方差异见 Let’s Encrypt [Challenge Types](https://letsencrypt.org/docs/challenge-types/)。

## 支持范围

| 系统 | 版本 | 架构 | 网络要求 |
|---|---|---|---|
| Debian | 12、13 | amd64、arm64 | 所选地址族有公网地址和默认路由 |
| Ubuntu | 24.04、26.04 | amd64、arm64 | 所选地址族有公网地址和默认路由 |
| Rocky Linux | 9.x、10.x | amd64、arm64 | 所选地址族有公网地址和默认路由 |
| AlmaLinux | 9.x、10.x | amd64、arm64 | 所选地址族有公网地址和默认路由 |

必须是以 systemd 作为 PID 1 的完整系统。普通 Docker 容器不是安装目标。IPv4-only、IPv6-only 和双栈 VPS 均可安装，但脚本不会把私网/NAT 映射地址当作本机公网地址，也不会在缺失地址族时自动回退。

安装阶段还必须能访问发行版软件源和项目固定的 GitHub 下载地址；这只用于取得依赖和经过 SHA-256 校验的程序，不改变安装完成后的严格出口规则。完全没有 IPv4/NAT64 出口的纯 IPv6 网络如果无法访问这些下载地址，会在下载阶段明确失败。

## 安装

准备好所选地址族的 DNS；若使用 Cloudflare DNS-01，再准备受限 Token。然后在 VPS 执行：

```bash
TMP="$(mktemp)" && \
curl -fsSL --retry 4 https://raw.githubusercontent.com/nekokemoji/neko/main/bootstrap.sh -o "$TMP" && \
bash "$TMP"
```

也可以下载仓库后运行：

```bash
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --network-mode dual
```

`bootstrap.sh` 会在受支持的系统上自动补齐 `tar`、`gzip` 等首次安装工具；不需要先手动安装 `tar`。标准一行命令本身仍需要系统已有 `curl` 与 `mktemp`，因为它们用于下载并保存入口脚本。

交互安装首先询问 `只装 IPv4`、`只装 IPv6` 或 `IPv4 + IPv6`，默认选择双栈；随后询问证书验证方式。证书处直接按回车选择 Cloudflare DNS-01，再粘贴 Token。iOS SSH 客户端也可以正常使用隐藏输入：粘贴后按回车即可，看不到字符是预期行为。

完全非交互的 DNS-01 安装应先把 Token 放进只有 root 可读的文件，再传文件路径；不要把 Token 本身写在命令行参数中：

```bash
sudo install -m 0600 /path/to/token-file /root/neko-cloudflare-token
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --network-mode ipv4-only \
  --acme-method cloudflare-dns-01 \
  --cloudflare-token-file /root/neko-cloudflare-token \
  --yes
```

`--network-mode` 可取 `ipv4-only`、`ipv6-only` 或 `dual`。为兼容已有自动化，非交互安装未提供该选项时仍默认 `dual`。HTTP-01 非交互安装可改用 `--acme-method http-01`。`--yes` 只跳过最后确认，不会跳过 DNS、所选地址族内核/路由、端口、SHA-256、配置或证书检查。

非交互安装如果既没有 Token 文件也没有显式指定 `--acme-method`，安装器会停止并说明用法，不会悄悄选择更依赖公网网络的 HTTP-01。

安装器从精确 tag 下载并校验固定 SHA-256，不解析 `latest`。当前 Neko 版本为 1.3.1，冻结核心见 `versions.env`：Xray 26.3.27、sing-box 1.13.14、Hysteria 2.10.0、Caddy 2.11.4、lego 5.2.2。Mihomo 1.19.29 只用于测试生成配置；qrc 0.9.0 是可选的终端二维码渲染器。

qrc 也只从上游精确版本下载并校验对应 amd64/arm64 SHA-256，但它不属于代理运行链路。下载、解压或运行检查失败时，安装和升级仍会完成，面板保留全部文字订阅链接，只不显示二维码。

## 云安全组与本机防火墙

安装完成时脚本会输出实际端口。必须为每个已安装地址族放行：

- TCP：443、SS2022、AnyTLS、Vision、XHTTP；
- UDP：Hysteria2 的完整 128 端口区间、TUIC、SS2022；
- TCP 8443 只监听 `127.0.0.1`，不要对公网放行。

只有选择 HTTP-01 时还必须向公网放行 TCP 80。DNS-01 不依赖公网 TCP 80；Caddy 仍会在本机监听该端口用于普通 HTTP 跳转，本机防火墙规则可能因此保留 80。

如果 firewalld 正在运行，脚本将规则添加到所选地址族默认路由网卡实际所属的 zone，并在 reload 后查询确认；如果 UFW 正在运行，则创建独立的 `NekoProxy` 应用规则。以后从面板补装另一族时，只为新增默认路由 zone 补规则；失败回滚不会删除预先存在的规则。卸载只移除 Neko 自己的规则。云厂商安全组仍需手动配置。

首次选择 HTTP-01 时，安装器会在证书验证前仅临时放行本机 TCP 80，并在成功、失败或正常中断时清理。firewalld 临时规则还带有 10 分钟自动过期保护。脚本不会改写未知的自定义 nftables/iptables 规则，也无法修改云厂商安全组。

Caddy 的公网订阅只启用 HTTP/1.1 与 HTTP/2，因此 443 只需要 TCP，不会出现“配置支持 HTTP/3 但 UDP 443 未放行”的不一致。

## 协议与安全默认值

| 协议 | 服务端核心 | 传输 |
|---|---|---|
| Hysteria2 | Hysteria | UDP，128 个随机连续端口 |
| TUIC v5 | sing-box | UDP |
| Shadowsocks 2022 | sing-box | TCP + UDP |
| AnyTLS | sing-box | TCP + TLS |
| VLESS REALITY Vision | Xray | TCP/RAW |
| VLESS REALITY XHTTP | Xray | TCP/XHTTP |

REALITY 的本地目标是 `127.0.0.1:8443`，由 Caddy 加载同一张受信 SAN 证书；该端口不对公网监听。

Hysteria2 在同一组端口上为每个已安装地址族运行一个子进程：单栈为一个，双栈为两个。双栈子进程受 systemd 共同监管，任一退出时停止另一进程并由 systemd 重启整组。两族共用协议凭据，但分别绑定 A/AAAA 地址和 `mode: 4`/`mode: 6` 出站，因此客户端订阅不会互相冲突，目标缺少对应地址族时也不会回退。

sing-box 链接是可以直接添加为 Remote Profile 的完整 JSON 配置，不是供其他客户端转换的节点列表。每份包含 Hysteria2、TUIC v5、Shadowsocks 2022、AnyTLS、VLESS REALITY Vision 五个节点；不包含 VLESS REALITY XHTTP，因为当前 sing-box 官方 V2Ray Transport 没有 XHTTP。生成格式由冻结的 sing-box 1.13.14 真实执行 `check`；使用更老的客户端可能不支持 AnyTLS 或当前配置字段。官方 Apple 客户端的分发状态可能变化，能否安装客户端与 JSON 格式是否正确是两个独立问题。

三套服务端核心默认拒绝客户端访问私有、回环、链路本地/云元数据等非公网地址，并拒绝 TCP 25，降低被导入订阅的设备利用去扫描 VPS 内网或滥发 SMTP 的风险。Hysteria 使用官方 [ACL](https://v2.hysteria.network/docs/advanced/ACL/)，sing-box 使用官方 [route reject action](https://sing-box.sagernet.org/configuration/route/rule_action/)，Xray 使用 [routing](https://xtls.github.io/en/config/routing.html) 与 [blackhole](https://xtls.github.io/en/config/outbounds/blackhole.html)。需要访问内网或 SMTP 的用户必须自行审计并修改渲染器。

## 终端控制面板

```bash
sudo neko
```

菜单提供：

```text
0. 退出
1. 查看当前 4 个或 8 个严格订阅链接与二维码
2. 开启 BBRv1
3. 按 IPv4/IPv6 重置订阅 URL（不会撤销已导入节点）
4. 刷新已安装地址族端点
5. IPv4/IPv6 安装管理
6. 卸载全部协议
```

选择第 1 项后，先显示所有现有文字链接，再按客户端和地址族选择一个二维码。二维码由 VPS 上固定版本的 qrc 本地生成，不调用在线二维码 API、不写入临时图片，完整订阅 URL 只通过标准输入传给 qrc，不出现在进程命令参数中。面板使用标准 4 模块留白、M 级纠错和紧凑 Unicode 显示；终端太窄、不是交互终端或 qrc 不可用时只给出说明，不影响文字链接和任何代理服务。iPad 可截图后用“照片”识别，也可以直接复制链接。

订阅令牌相当于密码。IPv4 与 IPv6 令牌相互独立；可以只重置一族，也可以同时重置。如果所选地址族尚未安装，面板会明确提示且不修改任何内容。重置令牌只会使对应旧下载 URL 返回 404；已经导入客户端的端口、密码和 UUID 不会因此失效。若怀疑节点凭据泄露，应卸载后重新安装或手动轮换全部协议凭据。

二维码本身等同于完整订阅链接和订阅密码。不要分享面板截图、二维码或完整 URL；二维码功能不会改变“重置订阅 URL”与“补装地址族”的含义。

安装管理只做“补装缺少的地址族”，不提供从双栈降级或删除单族，避免误删仍在使用的订阅。补装前必须先补齐基础域名和新专用域名的 DNS；脚本会重新检查路由、本机地址、证书方式和防火墙，保留原端口、协议凭据和已有地址族令牌，再用事务扩展证书、配置和服务。任何一步失败都会恢复补装前的状态。

端点刷新不会修改 DNS，而是重新读取当前已安装的域名。只有严格 DNS、对应默认路由和新地址确属本机全部通过后才会更新；地址没有变化时不会重写配置或重启服务。更新失败会恢复原状态、重新校验并确认四个服务；若自动恢复不完整，会保留状态备份并明确报告路径。

## 从 1.0.x / 1.1.x / 1.2.x 升级

旧版均视为已经安装双栈，所以升级前仍需确保基础、`v4.`、`v6.` 三个名称符合双栈 DNS 表，然后在新版源码目录运行：

```bash
sudo bash upgrade.sh
```

升级器保留协议端口、密码、UUID 与原订阅 URL；schema 1/2 的旧共享令牌会同时成为 IPv4 和 IPv6 令牌，因此链接不会无故变化。升级还会按需补齐严格 DNS 查询工具，并尽力安装固定版本的可选 qrc；qrc 失败不会让升级失败。状态、配置、程序文件、systemd 单元、可选 qrc 与证书会先备份；任何校验、证书或服务启动失败都会自动回滚。仅最早期 schema 1 的单域名旧 URL 会停用，需要重新导入严格链接。

## 证书续期

`neko-renew.timer` 每天检查一次并带随机延迟。续期严格沿用安装时选定的方式，不会自动切换：DNS-01 使用 root-only Token 文件，HTTP-01 使用 Caddy webroot。两种方式都会强制确认证书仍覆盖基础域名和全部已安装专用域名；证书实际变化后才重启读取证书的服务。

检查定时器和最近日志：

```bash
systemctl status neko-renew.timer
journalctl -u neko-renew.service --since '7 days ago'
```

DNS-01 用户如需轮换 Token，应创建权限相同的新 Token，然后安全覆盖凭据文件并立即试跑一次续期：

```bash
install -o root -g root -m 0600 /root/new-cloudflare-token \
  /var/lib/neko/credentials/cloudflare-dns-api-token
systemctl start neko-renew.service
journalctl -u neko-renew.service -n 80 --no-pager
```

确认成功后再撤销旧 Token。HTTP-01 用户则必须一直保持所有已启用域名直连本机且公网 TCP 80 可达。

## 测试与已知边界

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

测试使用真实冻结的 Xray、sing-box、Hysteria、Caddy、lego、Mihomo 和 qrc，分别验证 IPv4-only、IPv6-only、dual 三种服务端配置与 4/4/8 份订阅，覆盖 Remote Profile 真实核心解析、严格 DNS/CNAME 拒绝、Cloudflare/HTTP 两种 ACME 调度、证书从单栈扩展到双栈、API Token 权限与环境隔离、服务端出口阻断、升级迁移、按族令牌轮换、面板补装成功和失败回滚。二维码测试会把真实 qrc 的 Unicode 输出转换为图像，再独立解码并核对原 URL；同时验证链接只走标准输入，以及缺失、失败、窄终端和非交互输出都能安全降级。GitHub Actions 还在 8 个发行版镜像的 amd64/arm64 用户空间中实际执行对应架构的 qrc、语法、平台检测和三种模式渲染，共 16 个组合。

容器用户空间不等同于完整 systemd VM。真实 ACME、公网 IPv4/IPv6、云安全组、重启/卸载循环以及 Stash/Shadowrocket 真机导入仍必须在你自己的可重装 VPS 上做最终验收。详细范围见 [TESTING.md](TESTING.md)。

## 主要文件

```text
bootstrap.sh             固定源码提交的一行安装入口
install.sh               安装、硬门槛与失败回滚
upgrade.sh               旧版本到当前地址族状态模型的可回滚升级
versions.env             固定版本与双架构 SHA-256
lib/common.sh            系统、DNS、端口与状态逻辑
lib/render.sh            服务端配置与当前 4/8 份客户端订阅
lib/firewall.sh          firewalld/UFW 可逆规则
runtime/panel.sh         neko 终端面板
runtime/renew.sh         当前地址族 SAN 证书续期
runtime/hysteria-dual.sh Hysteria 单/双进程监管
systemd/                 服务与定时器
tests/                   本地与 CI 测试
```

## 上游官方资料

- [sing-box Remote Profile](https://sing-box.sagernet.org/clients/general/) 与 [JSON 配置结构](https://sing-box.sagernet.org/configuration/)
- [sing-box Hysteria2](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)、[TUIC](https://sing-box.sagernet.org/configuration/outbound/tuic/)、[Shadowsocks](https://sing-box.sagernet.org/configuration/outbound/shadowsocks/)、[AnyTLS](https://sing-box.sagernet.org/configuration/outbound/anytls/)、[VLESS](https://sing-box.sagernet.org/configuration/outbound/vless/) 出站
- [sing-box TUIC 入站](https://sing-box.sagernet.org/configuration/inbound/tuic/)、[Shadowsocks 入站](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)、[AnyTLS 入站](https://sing-box.sagernet.org/configuration/inbound/anytls/)
- [sing-box Dial Fields](https://sing-box.sagernet.org/configuration/shared/dial/) 与 [Route Rule](https://sing-box.sagernet.org/configuration/route/rule/)
- [Hysteria2 完整服务端配置（含 direct mode 4/6）](https://v2.hysteria.network/docs/advanced/Full-Server-Config/) 与 [端口跳跃](https://v2.hysteria.network/docs/advanced/Port-Hopping/)
- [Xray REALITY](https://xtls.github.io/en/config/transports/reality.html)、[XHTTP](https://xtls.github.io/en/config/transports/xhttp.html) 与 [Outbound targetStrategy/sendThrough](https://xtls.github.io/en/config/outbound.html)
- [Mihomo TUIC（含 SNI）](https://wiki.metacubex.one/en/config/proxies/tuic/) 与 [通用代理字段](https://wiki.metacubex.one/en/config/proxies/)
- [Stash 代理协议](https://stash.wiki/en/proxy-protocols/proxy-types)
- [Caddy 自定义 TLS 证书](https://caddyserver.com/docs/caddyfile/directives/tls)
- [lego CLI](https://go-acme.github.io/lego/usage/cli/) 与 [Cloudflare DNS provider](https://go-acme.github.io/lego/dns/cloudflare/)
- [Let’s Encrypt Challenge Types](https://letsencrypt.org/docs/challenge-types/)
- [qrc 官方仓库与命令行说明](https://github.com/fumiyas/qrc)
