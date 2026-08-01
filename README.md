# Neko

> 不只把代理协议装上，也帮你看懂这台 VPS 到底怎么样。

Neko 是一套面向独立公网 VPS 的终端部署与维护工具。它一次安装
Hysteria2、TUIC v5、Shadowsocks 2022、AnyTLS、Trojan TLS、
VLESS REALITY Vision 和 VLESS REALITY XHTTP，并为 Mihomo、Stash、Shadowrocket、sing-box
生成订阅。

项目没有网页面板。安装完成后，输入 `neko` 就能打开中文终端菜单。

## 为什么选择 Neko

Neko 最想解决的不是“再多装几个协议”，而是下面两个实际问题：

| 核心能力 | 小白能得到什么 | 熟悉网络的人能得到什么 |
|---|---|---|
| **VPS 一站式体检** | 不用再找一堆脚本，就能看硬件、服务、IP 风险、六个地区三网延迟和线路参考结论 | 可查看多数据库证据、BGP/RPKI/PTR、ASN 路径、源地址绑定后的真实出口和分地区路由 |
| **端到端严格 IPv4 / IPv6** | 选择 IPv4 就只走 IPv4，选择 IPv6 就只走 IPv6；不可用时明确失败，不偷偷换路 | 从订阅 DNS、节点地址、客户端配置、服务端监听、解析、路由到出站源地址都限制地址族 |

不少同类脚本把重点放在“协议能否安装”。Neko 在此基础上，把安装后的
**VPS 是否值得用、IP 是否存在明显风险、线路更适合哪个地区、服务是否健康**
也放进同一个面板。它不是大型跑分脚本的替代品，也不会拿一次测速冒充永久结论；
默认体检只读、轻量，外部数据源失败也不会影响代理服务。

除此之外，Neko 还提供：

- IPv4-only、IPv6-only、双栈三种安装方式，可在面板中补装缺少的地址族；
- 4 类客户端订阅：单栈 4 条，双栈 8 条；
- 本地生成订阅二维码，不把完整订阅链接交给在线二维码网站；
- Cloudflare DNS-01 和 HTTP-01 两种证书验证方式；
- 订阅 URL、节点凭据分开轮换，泄露时可以按影响范围处理；
- 安装、升级、补装、端点刷新和凭据轮换均带检查与失败回滚；
- Debian、Ubuntu、Rocky Linux、AlmaLinux 的 amd64 / arm64 自动化测试。

## 小白视频教程

面向小白的安装视频**目前还没有录制完成**。视频会从准备 VPS、获得并托管域名、
配置 DNS、运行 Neko、导入订阅一直讲到第一次 VPS 体检。发布后会立刻在这里补上
X 视频链接，不会让你在旧说明里到处找。

这个项目不会写完就丢。无论你只是照着步骤安装，还是会检查核心配置，我都会继续
跟进受支持的系统、冻结核心和客户端格式；重要改动先测试再发布，README 和视频说明
也会一起更新。

---

## 第一部分：小白照着做

如果你只想安装并使用，读完这一部分就够了。

### 1. 先确认你的 VPS 能不能装

支持以下系统和架构：

| 系统 | 版本 | 架构 |
|---|---|---|
| Debian | 12、13 | amd64、arm64 |
| Ubuntu | 24.04、26.04 | amd64、arm64 |
| Rocky Linux | 9.x、10.x | amd64、arm64 |
| AlmaLinux | 9.x、10.x | amd64、arm64 |

还必须满足：

- 是完整 VPS，使用 systemd；普通 Docker 容器不是安装目标；
- 你要安装的地址族有真实公网地址，并且这个地址属于 VPS 网卡；
- 对应地址族有默认路由；
- 不是只给内网地址、靠商家端口映射的 NAT VPS；
- 安装时能访问系统软件源和项目固定的 GitHub 下载地址。

脚本不会把不存在的 IPv6“变出来”，也不会为了安装成功而把 IPv6 节点偷偷改成
IPv4。

### 2. 选择 IPv4、IPv6，还是都装

安装一开始会询问：

```text
1. 只安装严格 IPv4
2. 只安装严格 IPv6
3. 同时安装严格 IPv4 与 IPv6
```

| 你的 VPS 情况 | 建议选择 | 结果 |
|---|---|---|
| 只有公网 IPv4 | 1 | 4 条严格 IPv4 订阅 |
| 只有公网 IPv6 | 2 | 4 条严格 IPv6 订阅 |
| IPv4、IPv6 都正常 | 3 | 4 条 IPv4 + 4 条 IPv6，共 8 条 |
| 两种地址都有，但暂时只想用一种 | 先装需要的一种 | 以后可从面板补装另一种 |

严格模式的含义很直接：

- IPv4 订阅从客户端连接 VPS 到 VPS 访问网站，全程只能用 IPv4；
- IPv6 订阅全程只能用 IPv6；
- 目标网站没有对应地址族时，访问失败是正确结果；
- 不自动回退，避免你以为自己测的是 IPv6，实际流量却从 IPv4 出去了。

### 3. 准备域名和 DNS

安装时输入的是**基础域名**，例如：

```text
node.example.com
```

不要输入 `v4.node.example.com` 或 `v6.node.example.com`。脚本会根据基础域名自动使用
`v4.`、`v6.` 专用订阅域名。

假设 VPS 的地址是 `VPS_IPv4` 和 `VPS_IPv6`，请按安装方式创建记录：

| 安装方式 | 需要创建的 DNS 记录 | 必须删除 |
|---|---|---|
| 只装 IPv4 | `node`：1 条 A；`v4.node`：同一条 A | 这两个名称的 AAAA 和 CNAME |
| 只装 IPv6 | `node`：1 条 AAAA；`v6.node`：同一条 AAAA | 这两个名称的 A 和 CNAME |
| IPv4 + IPv6 | `node`：1 条 A + 1 条 AAAA；`v4.node`：1 条 A；`v6.node`：1 条 AAAA | `v4.node` 的 AAAA/CNAME；`v6.node` 的 A/CNAME |

以 Cloudflare 为例，名称填写 `node`、`v4.node`、`v6.node`，内容填写 VPS 的公网
IP。所有记录都必须是 **仅 DNS（灰色云朵）**，不能打开橙色代理。

为什么要求这么严格？因为 `v4.` 必须只把客户端送到 VPS 的 IPv4，`v6.` 必须只送到
IPv6。CNAME、Cloudflare 橙云或多余记录都会改变实际连接地址，脚本会直接拒绝继续。

单栈安装不需要提前创建没有启用的那一族。例如只装 IPv4 时，不需要创建 `v6.node`；
以后从面板补装 IPv6 前再创建即可。

### 4. 选择证书方式

#### 推荐：Cloudflare DNS-01

这种方式由脚本临时在 DNS 中放入验证码，Let’s Encrypt 不需要从公网连接 VPS 的
80 端口。它对 IPv6 入站不稳定、云安全组复杂或单栈 VPS 更友好。

在 Cloudflare 创建一个专用 API Token，只给：

- `Zone / Zone / Read`
- `Zone / DNS / Edit`
- Zone Resources 只包含本项目使用的那个域名

不要使用 Global API Key，也不要给整个账户的无关权限。安装时粘贴 Token 后，终端
不显示任何字符是正常的；直接按回车即可。Token 会以 root-only 文件保存供续期使用，
不会写进订阅、命令行或普通日志。

同一个 Cloudflare Token 可以用于同一授权 zone 下的多台 VPS；是否分开创建 Token
取决于你是否希望单独撤销权限。为了降低一次泄露的影响，多台正式服务器使用各自的
受限 Token 更稳妥。

#### 兼容选项：HTTP-01

这种方式不需要 Cloudflare，也不需要 Token，但基础域名和所有已启用订阅域名都必须
从公网通过 TCP 80 访问到这台 VPS。双栈时，Let’s Encrypt 的 IPv4、IPv6 验证都必须
成功。

如果商家的 IPv6 入站路由、云安全组或上游网络有问题，HTTP-01 可能出现
`Network unreachable`。这不代表协议配置有问题；可以先修复入站网络，或者重新安装时
选择 DNS-01。

### 5. 开始安装

以 root 登录 VPS，完整复制下面的命令：

```bash
TMP="$(mktemp)" && \
curl -fsSL --retry 4 https://raw.githubusercontent.com/nekokemoji/neko/main/bootstrap.sh -o "$TMP" && \
bash "$TMP"
```

入口会自动补齐 `tar`、`gzip` 等首次安装工具，不需要提前手动安装 `tar`。这条命令
本身仍需要系统已有 `curl` 和 `mktemp`。

接下来按提示：

1. 选择要安装的网络类型；
2. 输入基础域名；
3. 输入 ACME 邮箱；
4. 选择证书方式，默认是 Cloudflare DNS-01；
5. DNS-01 模式下粘贴 Token；
6. 核对摘要，输入 `y`。

安装器会检查 DNS、地址、默认路由、端口和证书，再渲染配置并用真实冻结核心验证。
任何关键步骤失败都会停止；不会带着半套配置假装安装成功。

高级用户也可以下载仓库后使用参数：

```bash
sudo bash install.sh \
  --domain node.example.com \
  --email admin@example.com \
  --network-mode dual
```

`--network-mode` 可取 `ipv4-only`、`ipv6-only` 或 `dual`。完全非交互的 DNS-01
安装应使用只有 root 可读的 Token 文件，不要把 Token 直接写在命令行参数中：

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

HTTP-01 非交互安装可改用 `--acme-method http-01`。`--yes` 只跳过最终确认，不会
跳过 DNS、地址族、路由、端口、哈希、配置或证书检查。如果既没有 Token 文件，也没有
明确指定 `--acme-method`，安装器会停止并显示用法，不会擅自改用 HTTP-01。

完全没有 IPv4/NAT64 出口的纯 IPv6 VPS，如果无法访问软件源或固定下载地址，会在
下载阶段明确失败。这是安装依赖的可达性问题，不代表运行时允许跨地址族回退。

### 6. 放行云安全组

安装完成时会显示本机实际随机端口。云厂商控制台的安全组需要放行：

| 类型 | 端口 |
|---|---|
| TCP | 443、SS2022、AnyTLS、Trojan TLS、Vision、XHTTP |
| UDP | Hysteria2 的完整 128 端口区间、TUIC、SS2022 |
| TCP 80 | 仅 HTTP-01 必须公网放行 |
| TCP 8443 | **不要公网放行**，它只应监听 `127.0.0.1` |

脚本会管理正在使用的 firewalld 或 UFW 中属于 Neko 的规则，但无法替你修改云厂商
网页里的安全组。

### 7. 导入订阅

输入：

```bash
sudo neko
```

选择 `1` 查看订阅链接和二维码。每个已安装地址族会生成 4 条：

| 客户端 | 格式 | 节点数 |
|---|---|---:|
| Mihomo | YAML | 7 |
| Stash | YAML | 6 |
| Shadowrocket | Base64 文本订阅 | 7 |
| sing-box | 官方 Remote Profile JSON | 6 |

只装一个地址族时共 4 条，双栈时共 8 条。sing-box 订阅少一个 XHTTP 节点，是因为
当前冻结版本的 sing-box 官方 V2Ray Transport 不支持 XHTTP，并不是生成遗漏。

二维码在 VPS 本地生成，不调用在线二维码接口。iPad 可以截图后用“照片”识别，也可以
直接复制完整链接。二维码和链接都相当于订阅密码，不要公开分享。

面板显示的是基础域名上的通用下载链接。双栈 VPS 上，客户端可以通过当前可用的
IPv4 或 IPv6 先取回订阅；订阅里的 IPv4 / IPv6 节点仍然分别使用对应 IP 字面量，
代理连接和服务端出口不会因此跨地址族。早期版本的 `v4.` / `v6.` 下载链接继续可用，
升级后如遇到纯 IPv6 下载域名无法导入，可从面板重新复制通用链接。

“使用 sing-box 内核”不等于一定支持 sing-box 官方 Remote Profile。客户端还需要实现
对应导入方式和配置字段；遇到导入失败时，先确认链接复制完整，并查看该客户端使用的
内核版本。

### 8. 用内置体检看懂这台 VPS

在 `neko` 面板选择 `7`：

```text
1. 一键完整体检（推荐，只读）
2. 只看系统与硬件（离线、只读）
3. 只查 Neko、IP 质量与 BGP（联网、只读）
4. 真实三网线路（需输入 ROUTE）
5. 轻量性能（需输入 BENCH）
```

第一次建议选 `1`。你会看到：

- CPU、内存、磁盘、虚拟化、拥塞控制和时间同步；
- Neko 四个服务、证书覆盖和续期定时器；
- DNS、默认路由、本机地址、真实 IPv4/IPv6 出口；
- 多个公开数据库对 IP 位置、网络类型和风险标签的交叉结果；
- BGP 前缀、ASN、RPKI、注册信息和 PTR；
- 外部数据源能提供时的通俗结论。

想看线路时选 `4`，再选择广东、上海、北京、四川、湖北、辽宁或全部地区。报告会分别
测试电信、联通、移动，并在每个地区末尾集中显示最后有响应节点的延迟和线路判断。

需要正确理解结果：

- 这是 **VPS 发往国内参考目标** 的路径，通常称为回程；

| 位置 | 注释 |
|  ----  | ----  |
| 广东 | 香港/华南 |
| 上海 | 华东 |
| 北京 | 华北 |
| 湖北 | 华中 |
| 四川 | 西南 |
| 辽宁 | 东北 |

- 测试目标是该地区运营商的参考地址，不等于你的家庭宽带、某个区县或手机当前位置；
- 显示的是 traceroute 最后有响应节点的一次延迟，不是带宽、晚高峰速度或永久保证；
- ASN 可以辅助判断 163、CN2、169、9929、CMI、CMNET、CMIN2，但仅凭 AS4809
  不能可靠区分 CN2 GT 和 GIA；
- 数据库没有统一的“原生 IP”权威字段。Neko 会显示一致和分歧，不会根据单个网站
  武断地下结论。

某个外部数据库、Cloudflare、RIPEstat 或路由目标超时，只会显示“未测/提醒”，不会
停止或修改代理服务。

### 9. 面板每个功能有什么用

| 选项 | 功能 | 例子 |
|---:|---|---|
| 1 | 查看订阅链接和二维码 | 换手机后重新导入 |
| 2 | 开启 BBRv1 | 检查并启用系统自带 BBR，不安装第三方内核 |
| 3 | 管理订阅与节点访问 | 链接泄露时只换 URL；旧设备要撤销时换节点凭据 |
| 4 | 刷新地址族端点 | VPS 换了公网 IP，先改 DNS，再让 Neko 安全更新绑定地址 |
| 5 | IPv4/IPv6 安装管理 | 原来只装 IPv4，后来补齐 IPv6 后再补装 |
| 6 | 卸载 | 删除 Neko 服务和 Neko 自己创建的规则 |
| 7 | VPS 硬件、IP、网络体检 | 看 IP 风险、证书、服务和六地区三网线路 |

第 3 项的三种操作不要混淆：

| 操作 | 旧订阅 URL | 已导入的旧节点 | 什么时候用 |
|---|---|---|---|
| 重置订阅 URL | 失效 | 继续可用 | 只怀疑链接被看到 |
| 重置全部节点凭据 | 不变 | 全部失效 | 要撤销旧设备，但继续使用原订阅地址 |
| 紧急全部换新 | 失效 | 全部失效 | 链接和节点都可能泄露 |

IPv4、IPv6 的下载令牌彼此独立，所以只重置 URL 时可以选一族。协议凭据目前由两族
共同使用，因此“重置全部节点凭据”会一起撤销双栈旧节点，避免漏掉入口。

第 4 项不会替你修改 DNS。它只在新 DNS、默认路由和新地址归属全部正确时更新；
地址没变就不重启，失败会恢复原状态。

第 5 项只补装缺少的地址族，不提供从双栈删除单族，避免误删正在使用的订阅。补装前
先按第 3 节补齐新地址族的 DNS。

### 10. 常见问题

| 现象 | 通常原因 | 怎么处理 |
|---|---|---|
| 提示专用域名有多余 A/AAAA | 记录建错、输入了 `v4.`/`v6.` 域名或 DNS 缓存未更新 | 输入基础域名；按表删除异族记录和 CNAME；保持灰云 |
| DNS 查询看到 Cloudflare 的 `13.*`、`76.*` 等地址 | 打开了橙云代理 | 改成“仅 DNS”并等待公共 DNS 更新 |
| HTTP-01 的 IPv6 显示 `Network unreachable` | 上游 IPv6 入站、路由或安全组不可达 | 修复网络，或使用 DNS-01 |
| Let’s Encrypt 返回 429 / `rateLimited` | 相同域名组合短时间签发次数过多 | 按脚本显示的 UTC 恢复时间再试，不要反复重装 |
| 严格 IPv6 不能打开只有 A 记录的网站 | 正常的严格行为 | 改用严格 IPv4 订阅 |
| 旧版 `v6.` 订阅链接无法导入，但 IPv4 正常 | 客户端当前网络无法访问纯 IPv6 下载域名 | 升级 Neko，再从面板复制基础域名上的通用链接 |
| sing-box/Karing 导入失败 | 链接没复制完整、客户端导入方式或内核版本不兼容 | 重新复制完整链接，并确认支持官方 Remote Profile |
| 二维码没显示 | 可选 qrc 下载、终端宽度或运行环境不满足 | 直接复制文字链接；代理服务不受影响 |
| 体检某一项“未测” | 免费公开数据源或目标暂时不可达 | 稍后再测；不影响已安装服务 |

发生故障时，可以安全地检查：

```bash
systemctl is-active neko-caddy neko-sing-box neko-xray neko-hysteria
systemctl --no-pager --full status neko-sing-box neko-xray neko-hysteria
journalctl -u neko-sing-box -u neko-xray -u neko-hysteria -n 100 --no-pager
ip -4 route show default
ip -6 route show default
```

请不要公开 Cloudflare Token、完整订阅 URL、完整 `/etc/neko/state.json`、证书私钥、
SSH 密码或 SSH 私钥。

### 11. 升级

在最新源码目录执行：

```bash
sudo bash upgrade.sh
```

升级会保留端口、协议密码、UUID、REALITY 参数、订阅令牌、旧版下载 URL 和安装时
选择的证书方式。面板可能输出兼容性更好的新 URL 路径，但原链接仍继续提供同一份
订阅。升级前会备份状态、配置、程序、systemd 单元和证书；核心校验、证书或服务启动
失败时自动回滚。

证书续期由 `neko-renew.timer` 每天检查一次并随机延迟。查看状态：

```bash
systemctl status neko-renew.timer
journalctl -u neko-renew.service --since '7 days ago'
```

如果你只想安装使用，可以在这里停下。下面是设计、边界和验证细节。

---

## 第二部分：给想弄明白的人

### 项目定位与设计取舍

Neko 把三类工作放在同一套有状态、可回滚的流程里：

1. 部署七种互补协议，并输出四类客户端订阅；
2. 用端到端规则实现真正可验证的 IPv4 / IPv6 分离；
3. 在不引入常驻探针的前提下，提供硬件、服务、IP、BGP 和地区线路诊断。

因此它与只关注协议数量的安装脚本、只关注跑分的 VPS 测试脚本都不完全相同。Neko
选择较保守的范围：运行链路固定版本、关键改变真实核心校验、失败回滚；诊断默认只读、
外部证据降级；不会为了结果“看起来能用”而关闭证书验证或允许跨地址族回退。

当前 Neko 版本为 **1.7.1**。`versions.env` 冻结：

| 组件 | 版本 | 用途 |
|---|---:|---|
| Xray | 26.3.27 | VLESS REALITY Vision / XHTTP |
| sing-box | 1.13.14 | TUIC、SS2022、AnyTLS、Trojan 与配置验证 |
| Hysteria | 2.10.0 | Hysteria2 |
| Caddy | 2.11.4 | 订阅与本地 REALITY 目标 |
| lego | 5.2.2 | ACME |
| Mihomo | 1.19.29 | CI 中验证生成订阅 |
| qrc | 0.9.0 | 可选本地二维码 |
| NextTrace Tiny | 1.7.1 | 可选线路探测 |

所有下载都来自精确 tag 并校验对应架构 SHA-256，不解析不确定的 `latest`。qrc 和
NextTrace 属于可选组件；下载、校验或运行失败不会让安装、升级或代理服务失败。

### 订阅与协议矩阵

每个已安装地址族有独立下载令牌和 4 份订阅：

| 客户端 | IPv4 路径 | IPv6 路径 | 内容 |
|---|---|---|---|
| Mihomo | `https://<基础域名>/<IPv4令牌>/v4/mihomo.yaml` | `https://<基础域名>/<IPv6令牌>/v6/mihomo.yaml` | 7 个节点 |
| Stash | `https://<基础域名>/<IPv4令牌>/v4/stash.yaml` | `https://<基础域名>/<IPv6令牌>/v6/stash.yaml` | 6 个节点 |
| Shadowrocket | `https://<基础域名>/<IPv4令牌>/v4/shadowrocket.txt` | `https://<基础域名>/<IPv6令牌>/v6/shadowrocket.txt` | 7 个节点 |
| sing-box | `https://<基础域名>/<IPv4令牌>/v4/sing-box.json` | `https://<基础域名>/<IPv6令牌>/v6/sing-box.json` | 6 个节点 |

基础域名是订阅文件的通用控制面入口；双栈时可通过任一可用地址族下载。Caddy 仍保留
`v4.` / `v6.` 主机上的旧路径，因此升级不会让已添加的旧订阅失效。令牌和路径中的
`v4` / `v6` 决定返回哪一族配置，即使旧版本迁移后两族令牌相同也不会混淆。

协议分工：

| 协议 | 服务端核心 | 传输 | 四类订阅 |
|---|---|---|---|
| Hysteria2 | Hysteria | UDP + 128 端口跳跃区间 | 全部 |
| TUIC v5 | sing-box | UDP | 全部 |
| Shadowsocks 2022 | sing-box | TCP + UDP | 全部 |
| AnyTLS | sing-box | TCP + TLS | 全部 |
| Trojan TLS | sing-box | TCP + TLS | 全部 |
| VLESS REALITY Vision | Xray | TCP/RAW | 全部 |
| VLESS REALITY XHTTP | Xray | TCP/XHTTP | Mihomo、Shadowrocket |

Stash 和 sing-box 当前各 6 个节点，是因为它们没有包含 XHTTP；这属于明确的兼容性
取舍，不通过伪造字段强塞不支持的协议。TUIC 和 Trojan 即使在订阅中使用 IP 字面量
作为服务器，也显式保留基础域名 SNI，不开启 `skip-cert-verify`。
Trojan 使用独立随机 TCP 端口，并复用现有 SAN 域名证书；不会新增域名、Token 或
证书维护任务，也不会与订阅网站共用 TCP 443。

sing-box 文件是可直接添加为 Remote Profile 的完整官方 JSON 配置，不是节点列表或
转换接口。它包含 TUN、DNS、路由、选择器和六个代理出站，并由冻结的 sing-box
真实执行 `check`。

### 严格 IPv4 / IPv6 是怎样实现的

“严格”同时约束两个方向：

| 链路层次 | 严格 IPv4 | 严格 IPv6 |
|---|---|---|
| 订阅文件下载（控制面） | 基础域名，可用 IPv4 或 IPv6 | 基础域名，可用 IPv4 或 IPv6 |
| 节点 `server` | VPS IPv4 字面量 | VPS IPv6 字面量 |
| TLS 证书名称 | 基础域名，正常验证证书 | 基础域名，正常验证证书 |
| REALITY `serverName` / XHTTP Host | 基础域名 | 基础域名 |
| 服务端监听 | 精确绑定本机 IPv4 | 精确绑定本机 IPv6 |
| 目标解析 | 只取 IPv4 | 只取 IPv6 |
| 异族 IP 字面量 | 明确拒绝 | 明确拒绝 |
| 服务端出站 | 绑定 IPv4 源地址 | 绑定 IPv6 源地址 |
| 不可用时 | 失败，不回退 IPv6 | 失败，不回退 IPv4 |

“严格”约束的是客户端连接代理节点、服务端解析与出口的数据面，不要求用户必须先有
IPv6 才能下载一份 IPv6 配置。专用 `v4.` 只有 A、`v6.` 只有 AAAA，继续用于旧版
直连下载链接、证书兼容和地址族验证；新面板链接使用基础域名解决“IPv4 网络无法导入
IPv6 订阅”的循环依赖。

具体实现包括：

- Mihomo 写入 `ip-version: ipv4` / `ipv6`；
- sing-box Remote Profile 只使用所选族 DNS，路由拒绝另一族，且没有 DIRECT
  回退出站；
- sing-box 服务端设置同族解析策略、拒绝异族字面量，并用
  `inet4_bind_address` / `inet6_bind_address` 约束出口；
- Xray 为两族生成独立入站，使用精确 `listen`、`sendThrough` 和
  `ForceIPv4` / `ForceIPv6`；
- Hysteria 为每个已安装地址族生成独立配置和 `mode: 4` / `mode: 6` 子进程；
- 双栈 Hysteria 子进程由同一个 systemd 服务监管，任一退出时停止另一进程，再由
  systemd 重启整组。

只设置 IPv6 出站源地址并不足以拒绝目标中的 IPv4 字面量，因此显式异族拒绝规则是
必要安全边界，不能删除。

脚本能控制自己生成的配置和 VPS 端行为，但不能控制运营商 DNS64/NAT64、系统级
VPN、透明代理或客户端私自改写。验证严格模式时应实时查询测试目标的 A/AAAA，不能
永久假设某个网站只有一种记录。

### DNS、地址与安装硬门槛

安装器对每个启用的专用域名要求：

- 恰好 1 条对应族记录；
- 没有异族记录或 CNAME；
- 与基础域名对应记录一致；
- 地址真实配置在本机网卡，能够用于监听和出站源地址绑定；
- 对应地址族存在默认路由；
- IPv6 模式下内核启用 IPv6。

它还检查 TCP 80、443、8443 占用情况，冻结程序身份和哈希，真实核心配置解析，以及
服务重启后的持续运行状态。NAT VPS 是不同网络模型，不能通过删除“公网地址属于本机”
检查来伪装支持。

### ACME 与证书生命周期

Cloudflare DNS-01 是默认推荐方式。Token 保存于：

```text
/var/lib/neko/credentials/cloudflare-dns-api-token
```

凭据目录为 root 所有 `0700`，文件为 root 所有 `0600`。续期沿用安装方式，不会
偷偷切回 HTTP-01。

需要轮换 Token 时，先创建权限相同的新 Token，再安全覆盖文件并立即试跑续期：

```bash
install -o root -g root -m 0600 /root/new-cloudflare-token \
  /var/lib/neko/credentials/cloudflare-dns-api-token
systemctl start neko-renew.service
journalctl -u neko-renew.service -n 80 --no-pager
```

确认续期服务成功后，再到 Cloudflare 撤销旧 Token。

HTTP-01 是显式兼容选项，要求所有启用域名都能通过公网 TCP 80 到达当前 VPS。首次
验证前，脚本只临时开放本机 80 端口；firewalld 规则带 10 分钟过期保护，并在成功、
失败或正常中断时清理。

证书是一张覆盖基础域名和全部已启用专用域名的 SAN 证书。申请与续期有 10 分钟总
时限。lego 返回 `rateLimited` 时，脚本解析并显示官方 `retry after`，立即退出等待：

- 首次安装清理本次创建内容；
- 升级和补装恢复旧证书、配置与服务；
- 自动续期失败保留现有证书，等待定时器以后重试。

脚本不会反复申请、自动更换域名或切换验证方式来绕过 CA 限制。

### 服务、端口与安全默认值

Caddy 在基础域名发布通用订阅路径，并在 `v4.` / `v6.` 主机保留旧路径；公网订阅
只启用 HTTP/1.1 和 HTTP/2，因此 443 只需 TCP。REALITY 的本地目标为
`127.0.0.1:8443`，由 Caddy 加载同一张公开可信 SAN 证书；8443 不对公网监听。
DNS-01 不依赖公网 TCP 80，但 Caddy 仍可能在本机监听 80 处理普通 HTTP 跳转，因此
本机规则中保留 80 不等于证书偷偷改用了 HTTP-01。

三套核心默认拒绝客户端访问：

- 私有、回环和链路本地地址；
- 云元数据等非公网地址；
- TCP 25。

这降低了订阅被导入不可信设备后扫描 VPS 内网或滥发 SMTP 的风险。需要访问内网或
SMTP 的用户应自行审计并修改渲染器，而不是直接删除所有安全规则。

本机防火墙只操作 Neko 自己的规则：

- firewalld：添加到所选地址族默认路由网卡所属 zone，reload 后查询确认；
- UFW：创建独立 `NekoProxy` 应用规则；
- 未知自定义 nftables / iptables：不擅自改写；
- 云厂商安全组：只给出端口清单，不假装已经修改。

升级到 1.7.0 时，脚本会为旧安装生成独立 Trojan 端口和密码，并事务更新 Neko
自己的 firewalld/UFW 配置；后续校验或服务启动失败时，旧防火墙配置也一起恢复。
卸载只清理 Neko 创建的规则。补装失败也不会删除用户原先存在的放行规则。

### 有状态维护与回滚

以下操作都先备份，再原子更新状态、重新渲染、用冻结核心检查并重启四个服务：

- 安装和升级；
- 补装 IPv4 / IPv6；
- 刷新端点；
- 重置订阅 URL；
- 轮换全部节点凭据；
- 紧急全部换新。

任一步失败或正常中断都会恢复旧状态、旧配置和旧服务。只有自动恢复本身也失败时，
才保留 root-only 备份并明确要求停止后续操作。

端点刷新只读取现有域名并检查新地址，不修改 DNS。没有变化就不重写配置、不重启。
地址族管理只允许添加缺少的一族，暂不提供容易误删入口的单族卸载。

从尚未引入地址族状态模型的旧版本升级时，旧安装按双栈迁移，因此升级前仍要保证
基础、`v4.`、`v6.` 三个名称符合双栈 DNS。旧共享下载令牌会同时成为 IPv4 和 IPv6
令牌，路径中的 `v4` / `v6` 会区分通用下载内容，原严格链接也继续有效；只有最早期
单域名旧订阅需要重新导入。

### 体检的数据来源、结论与边界

默认完整体检由五部分组成：

| 部分 | 主要内容 | 是否联网 |
|---|---|---|
| 系统与硬件 | CPU、内存、Swap、磁盘、虚拟化、拥塞控制、时间同步 | 否 |
| Neko 健康 | 状态权限、四服务、证书签发者/到期/SAN、续期定时器 | 否 |
| 严格网络 | DNS、路由、本机地址、MTU、绑定源地址后的 HTTPS 出口 | 是 |
| IP 质量与注册 | 位置、网络类型、风险标签、ASN、BGP、RPKI、RIR、PTR | 是 |
| 通俗小结 | 正常、提醒、未测以及数据源一致/分歧 | 视前项 |

IP 质量并行交叉查询 ipapi.is、proxycheck.io、ipwho.is 和免密钥的 ipquery.io。
RIPEstat 用于前缀、源 ASN、RIS 可见性、RPKI 和注册资料。注册国家不等于实际机房，
Cloudflare 边缘位置也不等于商家销售地区。

“原生”“住宅”“广播”“解锁”没有一个跨数据库、跨服务通用的权威定义。Neko 输出
证据和一致数，不把营销标签包装成事实；“当前未见风险”也不代表未来不会变化。

线路测试使用固定版本 NextTrace Tiny 和固定核对过的 nt3 省级双栈参考目标。它从
当前已安装的精确 IPv4/IPv6 源地址，向广东、上海、北京、四川、湖北、辽宁三网目标
发送少量 TCP 探测。每个地址族的三条运营商路径并行，每条有总时限；地区与地址族
之间按选择顺序执行，避免把 VPS 瞬间打满。双栈选择全部六地时共 36 条路径；若目标
连续超时，整组测试可能接近 7 分钟。

报告显示：

- 末个有响应节点延迟；
- 精简 ASN 路径；
- 电信 163/CN2、联通 169/9929、移动 CMI/CMNET/CMIN2 的辅助判断；
- 每个地区三家运营商的集中结论。

它不声称测到真实用户的去程，也不声称预测晚高峰、带宽或未来路由。目标或元数据
服务拒绝探测时显示“未测”，不根据缺失数据硬猜。

CPU / 磁盘轻量测试必须输入 `BENCH` 才运行：CPU 默认单线程约 3 秒；磁盘在
`/var/tmp` 写入 128 MiB 并执行 `fdatasync`，完成、失败或中断都清理临时文件。
默认体检不跑性能测试，也不做高流量公网测速。

所有联网查询都有秒级超时。报告不会读取或输出订阅令牌、协议密码、证书私钥或
Cloudflare Token，但会把被检测的公网 IP 发送给上述公开数据库；公开截图前仍应
遮挡公网 IP。

### 测试范围与兼容性

本地完整测试：

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

测试使用真实冻结的 Xray、sing-box、Hysteria、Caddy、lego、Mihomo、qrc 和
NextTrace Tiny，覆盖：

- IPv4-only、IPv6-only、dual 三种服务端配置；
- 4 / 4 / 8 份订阅及 Remote Profile 真实核心解析；
- 严格 DNS、CNAME 与异族地址拒绝；
- Cloudflare DNS-01、HTTP-01、超时和 CA 限流；
- 单栈证书扩展到双栈；
- Token 权限、环境隔离和秘密不出现在输出中；
- 服务端同族出口和错误地址族阻断；
- 升级迁移、令牌/凭据轮换、端点刷新、补装和失败回滚；
- 二维码真实生成、图像转换、独立解码和原 URL 核对；
- 体检离线/联网、数据库一致/分歧/失败、RIPEstat、路线判断和清理。

GitHub Actions 在 Debian 12/13、Ubuntu 24.04/26.04、Rocky 9/10、Alma 9/10
的 amd64 / arm64 用户空间中运行平台、语法和三种模式渲染，共 16 个组合。

容器用户空间不等于完整 systemd VM。真实 ACME、公网双栈、云安全组、重启/卸载
循环，以及 Stash / Shadowrocket 真机导入仍需要在可重装 VPS 和真实客户端做最终
验收。详细范围见 [TESTING.md](TESTING.md)。

### 主要文件

```text
bootstrap.sh             固定源码提交的一行安装入口
install.sh               安装、硬门槛与失败回滚
upgrade.sh               旧版本到当前状态模型的可回滚升级
versions.env             固定版本与双架构 SHA-256
lib/common.sh            系统、DNS、端口与状态逻辑
lib/render.sh            服务端配置与 4/8 份客户端订阅
lib/firewall.sh          firewalld/UFW 可逆规则
runtime/panel.sh         neko 终端面板
runtime/diagnostics.sh   硬件、服务、IP、BGP 与线路体检
runtime/renew.sh         当前地址族 SAN 证书续期
runtime/hysteria-dual.sh Hysteria 单/双进程监管
systemd/                 服务与定时器
tests/                   本地与 CI 测试
```

### 上游官方资料

- [Cloudflare DNS-only](https://developers.cloudflare.com/dns/proxy-status/)、
  [创建 API Token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Let’s Encrypt Challenge Types](https://letsencrypt.org/docs/challenge-types/)
- [lego CLI](https://go-acme.github.io/lego/usage/cli/) 与
  [Cloudflare DNS provider](https://go-acme.github.io/lego/dns/cloudflare/)
- [sing-box Remote Profile](https://sing-box.sagernet.org/clients/general/) 与
  [JSON 配置](https://sing-box.sagernet.org/configuration/)
- [sing-box Hysteria2](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)、
  [TUIC](https://sing-box.sagernet.org/configuration/outbound/tuic/)、
  [Shadowsocks](https://sing-box.sagernet.org/configuration/outbound/shadowsocks/)、
  [AnyTLS](https://sing-box.sagernet.org/configuration/outbound/anytls/)、
  [Trojan](https://sing-box.sagernet.org/configuration/outbound/trojan/)、
  [VLESS](https://sing-box.sagernet.org/configuration/outbound/vless/)
- [Hysteria2 服务端完整配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
  与 [端口跳跃](https://v2.hysteria.network/docs/advanced/Port-Hopping/)
- [Xray REALITY](https://xtls.github.io/en/config/transports/reality.html)、
  [XHTTP](https://xtls.github.io/en/config/transports/xhttp.html) 与
  [targetStrategy/sendThrough](https://xtls.github.io/en/config/outbound.html)
- [Mihomo TUIC](https://wiki.metacubex.one/en/config/proxies/tuic/)、
  [Mihomo Trojan](https://wiki.metacubex.one/en/config/proxies/trojan/)、
  [Stash 代理协议](https://stash.wiki/en/proxy-protocols/proxy-types)
- [Caddy 自定义 TLS 证书](https://caddyserver.com/docs/caddyfile/directives/tls)
- [qrc](https://github.com/fumiyas/qrc)、[NextTrace](https://github.com/nxtrace/NTrace-core)
- [RIPEstat Data API](https://stat.ripe.net/docs/data-api/)、
  [ipapi.is](https://ipapi.is/developers.html)、
  [proxycheck.io](https://github.com/proxycheck/proxycheck-php)、
  [ipwho.is](https://ipwhois.io/documentation)、
  [ipquery.io](https://ipquery.io/)
- [oneclickvirt/nt3 省级三网目标注册表](https://github.com/oneclickvirt/nt3)

体检范围也参考了 [YABS](https://github.com/masonr/yet-another-bench-script) 与
[ECS](https://github.com/oneclickvirt/ecs) 的公开功能分类；Neko 没有复制或执行它们
的整套脚本。

### 使用边界

请只在你有权管理的服务器和网络中使用，并遵守所在地法律、服务商条款和组织政策。
严格地址族、证书验证、默认内网阻断和 TCP 25 拒绝都是项目的安全边界，不会为了
“看起来都能访问”而默认放宽。

如果你发现某个系统、客户端或网络环境与文档不一致，欢迎提供**去除敏感信息**后的
系统版本、错误行和服务日志。不要提交 Token、完整订阅 URL、完整 `state.json`、
证书私钥或 SSH 凭据。项目会持续维护，但每一次修复仍以可复现、可测试和可回滚为
前提。
