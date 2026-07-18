# Neko 多协议部署脚本

这是一个面向新手、但尽量保持可审计性的 Linux 服务端部署项目。它强制要求域名，只有 DNS 能解析且 Let’s Encrypt HTTP-01 证书签发成功后才会继续；安装完成后用 `neko` 进入纯终端控制面板，没有网页后台。

请只在你有权管理的服务器和网络中使用，并遵守所在地法律、服务商条款与组织政策。

## 新手一行安装

先把域名的 A 和/或 AAAA 记录直接解析到 VPS，并关闭 CDN/代理。然后登录 VPS，在终端只复制下面这一行：

```bash
TMP="$(mktemp)" && curl -fsSL --retry 4 https://raw.githubusercontent.com/nekokemoji/neko/main/bootstrap.sh -o "$TMP" && bash "$TMP"
```

引导脚本会下载固定的 Neko 1.0.4 源码，然后依次询问域名、ACME 邮箱和确认信息。它不会下载“最新”的 Xray、sing-box 等核心；核心版本和 SHA-256 仍由本项目的 `versions.env` 冻结。如果当前用户不是 root，引导脚本会在系统存在 `sudo` 时自动提权。

一行安装入口本身可在执行前查看：[bootstrap.sh](bootstrap.sh)。不建议使用 `curl ... | bash`，因为管道会占用标准输入，导致域名和邮箱的交互询问无法正常读取键盘输入。

## 支持范围

| 系统 | 版本 | 架构 | 网络 |
|---|---|---|---|
| Debian | 12、13 | amd64、arm64 | IPv4、IPv6、双栈 |
| Ubuntu | 24.04、26.04 | amd64、arm64 | IPv4、IPv6、双栈 |
| Rocky Linux | 9.x、10.x | amd64、arm64 | IPv4、IPv6、双栈 |
| AlmaLinux | 9.x、10.x | amd64、arm64 | IPv4、IPv6、双栈 |

必须是以 systemd 作为 PID 1 的完整系统。普通 Docker 容器不是安装目标。

## 协议与核心

| 协议 | 服务端核心 | 传输 | 证书处理 |
|---|---|---|---|
| Hysteria2 | Hysteria 官方核心 | UDP，128 个连续随机端口跳跃 | 直接读取自动签发证书 |
| TUIC v5 | sing-box | UDP | 直接读取自动签发证书 |
| Shadowsocks 2022 | sing-box | TCP + UDP | 协议本身不使用 TLS 证书 |
| AnyTLS | sing-box | TCP | 直接读取自动签发证书 |
| VLESS + REALITY + Vision | Xray | TCP/RAW | REALITY 借用本机 TLS 目标的同一张证书 |
| VLESS + REALITY + XHTTP | Xray | TCP/XHTTP | REALITY 借用本机 TLS 目标的同一张证书 |

REALITY 本身没有 PEM 证书字段。这里让它的 `target` 指向 `127.0.0.1:8443`：该端口只监听回环地址，由 Caddy 加载本域名的自动签发证书。因此它确实“借用自己的证书”，而不是把证书路径硬塞进不支持该字段的 Xray 配置。具体机制见 [Xray REALITY 文档](https://xtls.github.io/en/config/transports/reality.html) 和 [XHTTP 文档](https://xtls.github.io/en/config/transports/xhttp.html)。

## 冻结版本

版本集在 2026-07-18 核对，安装器只下载精确 tag，并对 amd64/arm64 分别校验固定 SHA-256；不会解析 `latest`。

| 组件 | 冻结版本 | 用途 |
|---|---:|---|
| [Xray-core](https://github.com/XTLS/Xray-core/releases/tag/v26.3.27) | 26.3.27 | 两个 VLESS + REALITY 入站 |
| [sing-box](https://github.com/SagerNet/sing-box/releases/tag/v1.13.14) | 1.13.14 | TUIC、SS2022、AnyTLS |
| [Hysteria](https://github.com/apernet/hysteria/releases/tag/app%2Fv2.10.0) | 2.10.0 | Hysteria2 与端口跳跃 |
| [Caddy](https://github.com/caddyserver/caddy/releases/tag/v2.11.4) | 2.11.4 | HTTPS 订阅和本机 REALITY TLS 目标 |
| [lego](https://github.com/go-acme/lego/releases/tag/v5.2.2) | 5.2.2 | ACME 首次签发与续期 |

完整哈希在 `versions.env`。升级时应同时更新版本、两个架构的哈希并重新跑测试，不要只改版本号。

## 安装前准备

1. 使用一台干净的、具有公网连通性的 VPS，并取得 root 权限。
2. 准备一个域名，例如 `node.example.com`，将 A 和/或 AAAA 记录直接解析到这台服务器。
3. 关闭该记录的 CDN、橙云或反向代理。随机协议端口不能穿过普通 HTTP CDN。
4. 在云厂商安全组中先放行 TCP 80 和 443；HTTP-01 只能通过 80 端口完成，见 [Let’s Encrypt 挑战类型说明](https://letsencrypt.org/docs/challenge-types/)。
5. 确保 TCP 80、443、8443 未被已有服务占用。安装器发现占用会拒绝覆盖。
6. 确保 `/var/tmp` 所在文件系统至少有 768 MiB 可用空间。安装器会在这里下载并解压冻结核心，完成或失败后都会清理；这可避开部分 VPS 只有几百 MiB 的 `/tmp` 内存盘。

域名解析只是第一道检查。真正的硬门槛是 Let’s Encrypt 从公网完成 HTTP-01 验证并签发证书；失败后安装会停止并回滚本项目已创建的文件。

## 安装

解压项目后运行：

```bash
cd neko
sudo bash install.sh --domain node.example.com --email admin@example.com
```

非交互方式：

```bash
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --yes
```

`--yes` 只跳过人工确认，不会跳过系统、域名、端口、校验和或证书检查。

安装时会为六个协议统一分配 10000–60000 范围内互不冲突的随机端口。Hysteria2 获得一个随机的 128 端口连续区间，第一个端口就是主端口；官方核心在 Linux 上用 nftables/iptables 把其余端口重定向到主端口，并在退出时清理规则。原理见 [Hysteria2 端口跳跃文档](https://v2.hysteria.network/docs/advanced/Port-Hopping/)。

安装结束后，查看实际端口：

```bash
sudo jq '.ports' /etc/neko/state.json
```

如果系统正在启用 firewalld 或 UFW，脚本会建立一个独立、可逆的 Neko 规则；其他防火墙不会被擅自改写。云安全组无法由脚本代管，仍须手动放行输出中的随机 TCP/UDP 端口和完整 Hysteria2 UDP 区间。回环端口 8443 不应对公网开放。

## HTTPS 订阅

三条订阅都是带随机令牌的 HTTPS URL：

| 客户端 | 节点数 | 内容 |
|---|---:|---|
| Mihomo 内核应用 | 6 | 全部协议 |
| Stash | 5 | 除 VLESS + REALITY + XHTTP 外的全部协议 |
| Shadowrocket 2.2.90 | 6 | 全部协议，结构化 YAML；节点直连 IP，SNI/证书仍绑定域名 |

Mihomo 格式依据其 [Hysteria2](https://wiki.metacubex.one/en/config/proxies/hysteria2/)、[TUIC](https://wiki.metacubex.one/en/config/proxies/tuic/)、[AnyTLS](https://wiki.metacubex.one/en/config/proxies/anytls/)、[VLESS](https://wiki.metacubex.one/en/config/proxies/vless/) 与 [XHTTP 传输](https://wiki.metacubex.one/en/config/proxies/transport/) 文档生成。Stash 使用单独的字段映射，其中 Hysteria2 使用 `auth`、TUIC 明确使用 v5，并根据 [Stash 协议文档](https://stash.wiki/en/proxy-protocols/proxy-types) 排除尚未支持的 XHTTP。Shadowrocket 使用单独的结构化 Clash/YAML 订阅，显式提供 `port-range`、TUIC v5、REALITY 与 `xhttp-opts`；对应能力以 [Apple App Store 版本记录](https://apps.apple.com/us/app/shadowrocket/id932747118) 为准。

Shadowrocket 的 HTTPS 订阅下载与节点连接可能走不同的 DNS 路径。为避免“订阅能下载、六个域名节点却全部超时”，安装器会为 Shadowrocket 固定域名当前的直连地址：双栈优先 A，只有 IPv6 时使用 AAAA。订阅 URL 仍是绑定域名的 HTTPS；Hysteria2、TUIC、AnyTLS 的 SNI、两种 REALITY 的 `serverName`、XHTTP Host 和证书校验也仍使用该域名。Mihomo 与 Stash 节点继续使用域名。选择结果保存在仅 root 可读的 `state.json` 中：

```bash
sudo jq -r '.subscription.shadowrocket_server' /etc/neko/state.json
```

订阅令牌等同于密码，不要公开。终端面板的重置功能会生成新令牌、重写 Caddy 路由并重启服务，旧 URL 随即返回 404。

从 Neko 1.0.2 或 1.0.3 原地升级到 1.0.4 时，解压新版源码后以 root 运行：

```bash
sudo bash update-shadowrocket.sh
```

更新器只替换公共辅助库和订阅渲染器、记录 Shadowrocket 直连地址、重新生成配置并重启 Caddy。它不会重装协议、变更端口、轮换密码/UUID/订阅令牌或重新申请证书；任何核心配置校验失败都会恢复原文件和状态。

## 终端控制面板

安装后输入：

```bash
neko
```

菜单严格为：

```text
0. 退出
1. 查看三个订阅链接
2. 开启 BBRv1
3. 重置订阅链接（旧链接失效）
4. 卸载全部协议
```

“开启 BBRv1”加载发行版内核提供的 `tcp_bbr`，写入 `/etc/sysctl.d/99-neko-bbr.conf`，卸载时删除该文件并尽力恢复启用前的实时值。脚本不会安装自定义内核，因此精确的 BBR 实现仍由发行版内核决定。

卸载需要输入大写 `UNINSTALL` 二次确认。它只删除本项目的 systemd 单元、固定目录、专用用户、专用防火墙规则、证书和 BBR 配置，不会删除用户的其他防火墙规则。

## 证书续期

`neko-renew.timer` 每天检查一次，并增加最长 12 小时随机延迟。lego 使用 Caddy 提供的 HTTP-01 webroot；证书实际变化后，会重启 Caddy、sing-box、Hysteria 和 Xray，让所有需要证书的协议读取新文件。

因此续期期间也必须满足：

- 域名继续直连这台服务器；
- TCP 80 保持公网可达；
- Caddy 服务正常运行。

检查状态：

```bash
systemctl status neko-renew.timer
journalctl -u neko-renew.service --since '7 days ago'
```

## 运维与排错

```bash
systemctl status neko-caddy neko-sing-box neko-xray neko-hysteria
journalctl -u neko-hysteria -n 100 --no-pager
journalctl -u neko-xray -n 100 --no-pager
```

重要限制：Xray 26.3.27 在校验时会明确警告 REALITY 监听非 443 端口可能增加被封锁风险。本项目按需求让每个协议使用独立随机端口，并把 443 留给 HTTPS 订阅，因此保留这个取舍。随机端口也不是认证或安全边界，真正的保护来自强随机凭据、TLS/REALITY 和订阅令牌。

## 测试

快速复现项目测试：

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

测试会验证 Shell 语法、16 个系统/架构检测组合、固定版本、随机端口无冲突、真实 sing-box/Xray/Caddy 配置、Hysteria 配置解析、6/5/6 节点数、Shadowrocket IPv4/IPv6 选择与原地升级、Stash 专用字段以及订阅令牌失效逻辑。详细范围和未覆盖事项见 [TESTING.md](TESTING.md)。

## 主要文件

```text
bootstrap.sh               新手一行安装入口与固定源码下载
install.sh                 安装、硬门槛、失败回滚
versions.env               固定版本和双架构 SHA-256
lib/common.sh              系统检测、随机端口、状态读取
lib/render.sh              服务端配置和三类订阅
lib/firewall.sh            firewalld/UFW 可逆规则
runtime/panel.sh           neko 终端面板
runtime/renew.sh           ACME 自动续期
update-shadowrocket.sh     旧安装原地升级与失败回滚
diagnose-shadowrocket-*.sh Shadowrocket 临时诊断工具
systemd/                   服务与定时器
tests/                     可重复测试
```

## 上游官方资料

- [sing-box TUIC 入站](https://sing-box.sagernet.org/configuration/inbound/tuic/)、[Shadowsocks 入站](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)、[AnyTLS 入站](https://sing-box.sagernet.org/configuration/inbound/anytls/)
- [Hysteria2 服务端配置](https://v2.hysteria.network/docs/getting-started/Server/)、[URI 规范](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [AnyTLS URI 规范](https://github.com/anytls/anytls-go/blob/main/docs/uri_scheme.md)
- [TUIC v5 规范与实现列表](https://github.com/tuic-protocol/tuic)
- [Caddy 自定义 TLS 证书](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Let’s Encrypt 证书说明](https://letsencrypt.org/docs/faq/)
