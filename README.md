# Neko 多协议部署脚本

Neko 是面向独立双栈 VPS 的终端部署工具。它安装 Hysteria2、TUIC v5、Shadowsocks 2022、AnyTLS、VLESS REALITY Vision 和 VLESS REALITY XHTTP，并为 Mihomo、Stash、Shadowrocket 各生成严格 IPv4 与严格 IPv6 两份订阅。

本项目没有网页面板。安装后使用 `neko` 打开终端菜单。请只在你有权管理的服务器和网络中使用，并遵守所在地法律、服务商条款与组织政策。

## 先说清楚：为什么是 6 条订阅

每个客户端都有两条链接，共 6 条：

| 客户端 | 严格 IPv4 | 严格 IPv6 | 节点数 |
|---|---|---|---:|
| Mihomo | `https://v4.<域名>/<令牌>/mihomo.yaml` | `https://v6.<域名>/<令牌>/mihomo.yaml` | 6 / 6 |
| Stash | `https://v4.<域名>/<令牌>/stash.yaml` | `https://v6.<域名>/<令牌>/stash.yaml` | 5 / 5 |
| Shadowrocket | `https://v4.<域名>/<令牌>/shadowrocket.txt` | `https://v6.<域名>/<令牌>/shadowrocket.txt` | 6 / 6 |

这里没有“自动版”，也没有 IPv4 优先后回退 IPv6。严格约束覆盖完整链路：

- IPv4 下载域名只有 A，没有 AAAA；IPv6 下载域名只有 AAAA，没有 A。
- 六份配置中的节点 `server` 都是对应族的 IP 字面量，客户端不再对节点域名做双栈选择。
- Mihomo 另外写入 `ip-version: ipv4` 或 `ip-version: ipv6`。
- TLS SNI、证书主机名、REALITY `serverName` 和 XHTTP Host 始终保留基础域名。
- 服务端为 IPv4/IPv6 分别监听，并把来自该入口的流量路由到同族直连出口；sing-box 在路由阶段只解析同族地址、拒绝异族 IP 字面量并绑定同族源地址，Xray 使用 `ForceIPv4`/`ForceIPv6` 和源地址绑定，Hysteria 使用 `mode: 4`/`mode: 6` 双实例。
- 对应地址族不可用时直接失败，不会由生成配置或 VPS 出站回退到另一族。例如只有 A、没有 AAAA 的目标通过严格 IPv6 订阅应访问失败。

脚本能约束 DNS 记录和生成的客户端配置，但不能控制客户端之外的网络。运营商 DNS64/NAT64、系统级 VPN、透明代理或客户端自身改写仍可能改变实际链路；任何服务端脚本都无法绕过这一边界。

## 必须先配置的 Cloudflare DNS

假设基础域名是 `node.example.com`，VPS 地址为 `VPS_IPv4` 与 `VPS_IPv6`：

| 类型 | 名称 | 内容 | Cloudflare 状态 |
|---|---|---|---|
| A | `node` | `VPS_IPv4` | DNS only（灰云） |
| AAAA | `node` | `VPS_IPv6` | DNS only（灰云） |
| A | `v4.node` | `VPS_IPv4` | DNS only（灰云） |
| AAAA | `v6.node` | `VPS_IPv6` | DNS only（灰云） |

不要给 `v4.node` 添加 AAAA，也不要给 `v6.node` 添加 A。每个名称只允许表中这一条对应记录；三个名称必须指向同一台 VPS。Cloudflare 说明了代理记录返回的是 Cloudflare Anycast 地址而不是源站地址，因此这里必须使用 [DNS-only](https://developers.cloudflare.com/dns/proxy-status/)。

安装器会硬性检查：

- `v4.node.example.com` 恰好 1 条 A、0 条 AAAA；
- `v6.node.example.com` 恰好 1 条 AAAA、0 条 A；
- 基础域名的 A/AAAA 与两个专用域名完全一致；
- A 与 AAAA 地址确实配置在本机网卡上，可分别用于服务监听和出站源地址绑定；
- 内核启用 IPv6，同时存在 IPv4 与 IPv6 默认路由；
- TCP 80、443、8443 未被其他程序占用；
- Let’s Encrypt 为基础、v4、v6 三个名称成功签发同一张 SAN 证书。

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

也可在安装菜单中选择 HTTP-01 兼容模式。HTTP-01 不需要 Token，但 Let’s Encrypt 只能通过 TCP 80 验证；基础、v4、v6 三个名称的所有公网验证视角都必须能连到本机。两种模式不会同时运行，也不会自动互相回退。官方差异见 Let’s Encrypt [Challenge Types](https://letsencrypt.org/docs/challenge-types/)。

## 支持范围

| 系统 | 版本 | 架构 | 网络要求 |
|---|---|---|---|
| Debian | 12、13 | amd64、arm64 | 公网双栈 |
| Ubuntu | 24.04、26.04 | amd64、arm64 | 公网双栈 |
| Rocky Linux | 9.x、10.x | amd64、arm64 | 公网双栈 |
| AlmaLinux | 9.x、10.x | amd64、arm64 | 公网双栈 |

必须是以 systemd 作为 PID 1 的完整系统。普通 Docker 容器不是安装目标。单栈 VPS 会被明确拒绝，因为它无法满足严格 IPv4/IPv6 两套订阅的要求。

## 安装

准备好上述 DNS 和 Cloudflare Token 后，在 VPS 执行：

```bash
TMP="$(mktemp)" && \
curl -fsSL --retry 4 https://raw.githubusercontent.com/nekokemoji/neko/main/bootstrap.sh -o "$TMP" && \
bash "$TMP"
```

也可以下载仓库后运行：

```bash
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com
```

`bootstrap.sh` 会在受支持的系统上自动补齐 `tar`、`gzip` 等首次安装工具；不需要先手动安装 `tar`。标准一行命令本身仍需要系统已有 `curl` 与 `mktemp`，因为它们用于下载并保存入口脚本。

交互安装会先询问证书验证方式；直接按回车选择 Cloudflare DNS-01，再粘贴 Token。iOS SSH 客户端也可以正常使用隐藏输入：粘贴后按回车即可，看不到字符是预期行为。

完全非交互的 DNS-01 安装应先把 Token 放进只有 root 可读的文件，再传文件路径；不要把 Token 本身写在命令行参数中：

```bash
sudo install -m 0600 /path/to/token-file /root/neko-cloudflare-token
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --acme-method cloudflare-dns-01 \
  --cloudflare-token-file /root/neko-cloudflare-token \
  --yes
```

HTTP-01 非交互安装可改用 `--acme-method http-01`。`--yes` 只跳过最后确认，不会跳过 DNS、双栈内核、端口、SHA-256、配置或证书检查。

非交互安装如果既没有 Token 文件也没有显式指定 `--acme-method`，安装器会停止并说明用法，不会悄悄选择更依赖公网网络的 HTTP-01。

安装器从精确 tag 下载并校验固定 SHA-256，不解析 `latest`。当前 Neko 版本为 1.2.1，冻结核心见 `versions.env`：Xray 26.3.27、sing-box 1.13.14、Hysteria 2.10.0、Caddy 2.11.4、lego 5.2.2；Mihomo 1.19.29 只用于测试生成配置。

## 云安全组与本机防火墙

安装完成时脚本会输出实际端口。必须同时为 VPS 的 IPv4 与 IPv6 入站放行：

- TCP：443、SS2022、AnyTLS、Vision、XHTTP；
- UDP：Hysteria2 的完整 128 端口区间、TUIC、SS2022；
- TCP 8443 只监听 `127.0.0.1`，不要对公网放行。

只有选择 HTTP-01 时还必须向公网放行 TCP 80。DNS-01 不依赖公网 TCP 80；Caddy 仍会在本机监听该端口用于普通 HTTP 跳转，本机防火墙规则可能因此保留 80。

如果 firewalld 正在运行，脚本将规则添加到 IPv4/IPv6 默认路由网卡实际所属的 zone，并在 reload 后查询确认；如果 UFW 正在运行，则创建独立的 `NekoProxy` 应用规则。卸载只移除 Neko 自己的规则。云厂商安全组仍需手动配置。

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

Hysteria2 在同一组端口上运行 IPv4 与 IPv6 两个受 systemd 共同监管的进程。两者共用协议凭据，但分别绑定 A/AAAA 地址和 `mode: 4`/`mode: 6` 出站，因此客户端订阅不会互相冲突，目标缺少对应地址族时也不会回退。

三套服务端核心默认拒绝客户端访问私有、回环、链路本地/云元数据等非公网地址，并拒绝 TCP 25，降低被导入订阅的设备利用去扫描 VPS 内网或滥发 SMTP 的风险。Hysteria 使用官方 [ACL](https://v2.hysteria.network/docs/advanced/ACL/)，sing-box 使用官方 [route reject action](https://sing-box.sagernet.org/configuration/route/rule_action/)，Xray 使用 [routing](https://xtls.github.io/en/config/routing.html) 与 [blackhole](https://xtls.github.io/en/config/outbounds/blackhole.html)。需要访问内网或 SMTP 的用户必须自行审计并修改渲染器。

## 终端控制面板

```bash
sudo neko
```

菜单提供：

```text
0. 退出
1. 查看六个严格订阅链接
2. 开启 BBRv1
3. 重置订阅 URL（不会撤销已导入节点）
4. 刷新严格 IPv4/IPv6 端点
5. 卸载全部协议
```

订阅令牌相当于密码。重置令牌只会使旧下载 URL 返回 404；已经导入客户端的端口、密码和 UUID 不会因此失效。若怀疑节点凭据泄露，应卸载后重新安装或手动轮换全部协议凭据。

## 从 1.0.x / 1.1.x / 1.2.0 升级

先创建 `v4.<基础域名>` 和 `v6.<基础域名>` 记录，再在新版源码目录运行：

```bash
sudo bash upgrade.sh
```

升级器保留协议端口、密码、UUID 与订阅令牌；扩展证书到三个域名，生成六份订阅，安装 Hysteria 双实例监管器，并重建真正按入口分流的同族出口。状态、配置、程序文件、systemd 单元与证书会先备份；任何校验、证书或服务启动失败都会自动回滚。旧的单域名订阅 URL 升级后停用，需要在客户端重新导入对应的严格链接。

## 证书续期

`neko-renew.timer` 每天检查一次并带随机延迟。续期严格沿用安装时选定的方式，不会自动切换：DNS-01 使用 root-only Token 文件，HTTP-01 使用 Caddy webroot。两种方式都会强制确认证书仍覆盖基础、v4、v6 三个名称；证书实际变化后才重启读取证书的服务。

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

确认成功后再撤销旧 Token。HTTP-01 用户则必须一直保持三个域名直连本机且公网 TCP 80 可达。

## 测试与已知边界

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

测试使用真实冻结的 Xray、sing-box、Hysteria、Caddy、lego 和 Mihomo，覆盖六份订阅、严格 DNS 拒绝规则、Cloudflare/HTTP 两种 ACME 调度、API Token 文件权限与环境隔离、服务端出口阻断、升级成功/回滚、订阅令牌轮换和配置解析。GitHub Actions 还在 8 个发行版镜像的 amd64/arm64 用户空间中执行语法与平台检测，共 16 个组合。

容器用户空间不等同于完整 systemd VM。真实 ACME、公网 IPv4/IPv6、云安全组、重启/卸载循环以及 Stash/Shadowrocket 真机导入仍必须在你自己的可重装 VPS 上做最终验收。详细范围见 [TESTING.md](TESTING.md)。

## 主要文件

```text
bootstrap.sh             固定源码提交的一行安装入口
install.sh               安装、硬门槛与失败回滚
upgrade.sh               旧版本到当前严格双栈布局的可回滚升级
versions.env             固定版本与双架构 SHA-256
lib/common.sh            系统、DNS、端口与状态逻辑
lib/render.sh            服务端配置与六份客户端订阅
lib/firewall.sh          firewalld/UFW 可逆规则
runtime/panel.sh         neko 终端面板
runtime/renew.sh         三域名 SAN 证书续期
runtime/hysteria-dual.sh Hysteria IPv4/IPv6 双进程监管
systemd/                 服务与定时器
tests/                   本地与 CI 测试
```

## 上游官方资料

- [sing-box TUIC 入站](https://sing-box.sagernet.org/configuration/inbound/tuic/)、[Shadowsocks 入站](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)、[AnyTLS 入站](https://sing-box.sagernet.org/configuration/inbound/anytls/)
- [sing-box Dial Fields](https://sing-box.sagernet.org/configuration/shared/dial/) 与 [Route Rule](https://sing-box.sagernet.org/configuration/route/rule/)
- [Hysteria2 完整服务端配置（含 direct mode 4/6）](https://v2.hysteria.network/docs/advanced/Full-Server-Config/) 与 [端口跳跃](https://v2.hysteria.network/docs/advanced/Port-Hopping/)
- [Xray REALITY](https://xtls.github.io/en/config/transports/reality.html)、[XHTTP](https://xtls.github.io/en/config/transports/xhttp.html) 与 [Outbound targetStrategy/sendThrough](https://xtls.github.io/en/config/outbound.html)
- [Mihomo TUIC（含 SNI）](https://wiki.metacubex.one/en/config/proxies/tuic/) 与 [通用代理字段](https://wiki.metacubex.one/en/config/proxies/)
- [Stash 代理协议](https://stash.wiki/en/proxy-protocols/proxy-types)
- [Caddy 自定义 TLS 证书](https://caddyserver.com/docs/caddyfile/directives/tls)
- [lego CLI](https://go-acme.github.io/lego/usage/cli/) 与 [Cloudflare DNS provider](https://go-acme.github.io/lego/dns/cloudflare/)
- [Let’s Encrypt Challenge Types](https://letsencrypt.org/docs/challenge-types/)
