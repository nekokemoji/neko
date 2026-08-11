# Neko 1.11.1 测试范围

最近核对日期：2026-08-10（America/Los_Angeles）。

这份文件把“已经由自动测试验证的内容”和“必须在真实 VPS/客户端验证的内容”分开，避免把容器或静态检查描述成完整系统实装。

## 本地核心测试

执行方式：

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

`tests/fetch-pinned-tools.sh` 从上游精确 release tag 下载测试二进制并校验 `versions.env` 中固定的 SHA-256。`tests/run.sh` 当前覆盖：

- 所有 Shell 文件通过 `bash -n` 与 ShellCheck；缺少 ShellCheck、PyYAML 或独立二维码解码器时测试失败而不是跳过。
- `detect_platform` 模拟 Debian 12/13、Ubuntu 24.04/26.04、Rocky 9/10、AlmaLinux 9/10 的 amd64/arm64，共 16 个允许组合，并验证不支持版本会被拒绝。
- Debian 与 RHEL 两条依赖安装分支使用 mock 调用验证；旧安装升级时若缺少 `dig`，只补 `bind9-dnsutils`/`bind-utils`，且在修改 Neko 前完成。
- IPv4-only、IPv6-only、dual 的严格 DNS 正例通过；查询使用绝对名称和明确的 A/AAAA 类型，不受 libc `AI_ADDRCONFIG` 或 DNS search 后缀影响；异族记录、CNAME、多个地址和基础域名不匹配都会失败。
- firewalld 只根据已安装地址族的默认路由网卡寻找实际 zone，而不是盲目使用 default zone；补装另一族时不会接管或回滚预先存在的区域规则。
- Bootstrap 离线解压固定源码包、核对 1.11.1 标记并清理临时目录；模拟精简系统缺少 `tar`/`gzip` 时会先通过系统包管理器补齐。
- 所有发行版容器都用各自真实的 `awk` 解析模拟 DNS 结果；其中 Debian 12 的旧版 mawk 不支持正则区间表达式，测试会确认严格 IPv4 解析不依赖该语法。
- HTTP-01 在签发前为 firewalld/UFW 临时放行 TCP 80，并在完成后只删除本次创建的临时规则；firewalld 规则带自动过期保护。
- Xray 26.3.27、sing-box 1.13.14、Hysteria 2.10.0、Caddy 2.11.4、lego 5.2.2、Mihomo 1.19.29、可选 qrc 0.9.0 与 NextTrace Tiny 1.7.1 的版本身份和所需 CLI 参数。
- Cloudflare DNS-01 与 HTTP-01 分别传递正确的 lego 参数；DNS-01 只暴露固定的 `_FILE` 凭据变量，清除原始 Token、旧式变量和外部文件变量。
- 连续模拟 1000 次 lego 快速失败，确认公共 ACME 保护完整保留原始退出码与错误输出，不会再由 Bash `coproc` 竞态产生 `Bad file descriptor`；Cloudflare `9109` 会给出 Token 类型、有效性、最小权限与 Zone 范围提示。发行版矩阵也会在全部 16 个系统/架构组合中执行快速失败路径。
- 模拟 lego 收到 Let’s Encrypt `rateLimited` 后准备长时间等待，确认公共 ACME 保护在 5 秒内终止、保留并显示 `retry after`，返回临时失败；另模拟无输出挂起，确认 10 分钟总时限的可配置短时测试路径。发行版矩阵也会在全部 16 个系统/架构组合中执行快速限额终止路径。
- Cloudflare Token 内容格式、凭据目录 `0700`、文件 `0600` 与非符号链接约束。
- 真实 `sing-box check` 与 `xray run -test` 分别解析 IPv4-only、IPv6-only、dual 三种服务端配置；双栈四个方向的 sing-box Remote Profile 全部由真实核心解析。
- Hysteria 的单栈配置或双栈四个配置分别读取并执行到端口跳跃帮助程序查找阶段；测试刻意不给它 nftables/iptables，避免改动宿主防火墙。
- 真实 Caddy 校验三种模式，并验证从单栈补装到双栈时，旧证书尚未包含新增 SAN 的短暂配置仍可加载；随后证书扩容参数必须带齐全部活动域名。
- 真实 Mihomo 分别解析 IPv4→IPv4、IPv6→IPv6、IPv4→IPv6 与 IPv6→IPv4 配置。
- 订阅目录按模式恰好生成 4、4、16 个文件；不存在未安装地址族的残留订阅或 Hysteria 配置。
- Mihomo 7 个节点全部使用箭头左侧入口 IP 字面量和 `ip-version`；Stash 6 个节点、Shadowrocket 8 个节点也固定入口 IP，其中 AnyReality 只加入 Shadowrocket 和 sing-box。
- 新安装的 sing-box 每份 Remote Profile 含 7 个入口族 IP 节点、TUN、出口族 DoH、异族拒绝规则和唯一的 `PROXY` 最终出口；测试确认不存在 DIRECT 或 XHTTP，TLS SNI 与 REALITY 参数仍保持基础域名。
- Mihomo TUIC 明确包含 TLS SNI；其余证书主机名、REALITY `serverName` 与 XHTTP Host 也保持基础域名，不被 IP 字面量替换。
- Caddy 在基础域名发布四个独立线路路径，同时保留 v4 主机只发布 v4 文件、v6 主机只发布 v6 文件的旧链接，并禁用公网 HTTP/3；相同旧令牌迁移时也由路径中的 `v4` / `v6` 正确区分内容。
- 默认双栈时 sing-box 的 20 个入站（含四个 AnyReality）与 Xray 的 8 个入站按箭头左侧本机 IPv4/IPv6 地址分开监听，再按箭头右侧进入对应出口；单栈时只保留对应的 5 个与 2 个入站。sing-box 在路由阶段按出口只解析对应族地址、拒绝异族 IP 字面量，再进入源地址绑定出口。
- sing-box 服务端本地 DNS 明确使用 Go 解析路径，避免 Debian 12 镜像中的 systemd-resolved D-Bus 异常同时拖死 TUIC、SS2022、AnyTLS 与 Trojan 的域名出口。
- Hysteria 四个方向分别使用所需的 `mode: 4`/`mode: 6` 和 `bindIPv4`/`bindIPv6`；用假核心动态验证监管脚本可启动单个子进程，也可同时启动四个进程并在任一退出时终止其余进程，交由 systemd 重启完整进程组。
- 三个服务端核心都阻断私有/回环/链路本地地址和 TCP 25；Xray、sing-box 配置由真实核心校验，Hysteria ACL 与同族 direct 出站由配置加载路径和结构化断言校验。
- 随机端口连续运行 50 轮；状态加载还断言同族/跨族两个 Hysteria2 128 端口区间和两组六个单端口全局无冲突。
- 双栈四个订阅令牌分别存储；按入口轮换时同时换新该入口的同族/跨族 URL，未选入口令牌与链接保持不变，未安装地址族为明确的无操作。
- 面板可在不改变 URL 的情况下同时轮换八种协议的 AnyTLS、AnyReality、REALITY 等认证字段，也可在一个事务中紧急换新节点凭据和全部已安装地址族令牌。IPv4-only、IPv6-only、dual 均验证端口、域名、证书、REALITY 参数和未选令牌保持不变；旧凭据从服务端配置与全部订阅消失，终端不输出协议密码。服务失败、意外退出和回滚服务仍失败分别覆盖完整恢复、EXIT trap 恢复及 root-only 备份保留。
- 面板为每个可用线路方向列出 Mihomo、Stash、Shadowrocket、sing-box 四个二维码选项，双栈恰好 16 项；真实 qrc 的紧凑 Unicode 输出会转换为 PBM 并由 zbar 独立解码，确认内容与原 URL 完全一致。
- 面板把 URL 只写入 qrc 标准输入，命令参数不含 URL；qrc 缺失、执行失败、终端太窄或输出不是交互终端时均返回文字链接而不终止面板。
- 面板第 8 项先显示确认的 IP 被墙、“送中”、入站与出站文案，再询问客户端、被墙入口和“送中”出口；四种组合均验证推荐/备用映射、两条真实客户端订阅 URL、两次二维码输出和只读状态。
- 面板第 7 项列出 GOECS、NodeQuality 与 Neko 三网线路检测；离线替身验证前两项无需 Neko 确认直接运行，线路菜单严格使用广东、上海、北京、四川、湖北、辽宁、全部地区的顺序。
- Neko 自带线路组件只包含六地三网回程：每个目标固定 100 包 ICMP，ICMP 不回应时改测 100 次 TCP 连接，显示 ASN 路径、平均/P95 延迟、丢包或 TCP 成功率；不包含旧版硬件、IP 质量、BGP 注册和跑分模块。
- AnyReality 在新安装和旧版升级时默认启用，使用独立端口、密码、REALITY 密钥和严格出口路由；仅加入 sing-box 与 Shadowrocket，Mihomo、Stash 保持不变，防火墙同步开放对应 TCP 端口。面板不再提供功能 9 或 AnyReality 卸载入口。
- 控制面板端点刷新在地址未变化时不重启；模拟新地址更新成功、服务失败后完整回滚，以及回滚服务仍失败时保留状态备份。
- 控制面板从 IPv4-only 补装 IPv6 的成功、第二组跨族端口无碰撞、两个跨族令牌、证书扩容、重复请求无操作、服务失败后配置/证书/firewalld 自动回滚；恢复路径还会拒绝根目录等危险目标。
- 分别从 schema 1、schema 2 与 schema 3 的双栈/IPv4-only/IPv6-only 模拟升级到 Neko 1.11.1，确认原端口、协议凭据、REALITY 参数、安装模式、令牌和旧订阅 URL 继续可用；升级只新增 AnyReality 及旧版缺少的跨族/Trojan 数据。schema 4 已有 AnyReality 且端口正在监听时，升级仍原样保留其身份，同时继续拒绝状态文件中的真实端口重叠。
- 模拟 firewalld 管理的旧安装升级，确认 Neko 专用服务规则加入 AnyReality、Trojan 与跨族 TCP/UDP 端口；升级成功安装精简线路脚本与 NextTrace，并移除旧版完整体检，后续服务失败时恢复升级前状态、配置、systemd 单元、防火墙和可选组件。
- systemd 单元的关键沙箱、能力与续期写路径静态断言。

本次修改在当前 Ubuntu 24.04 用户空间中完成；这里 PID 1 不是 systemd，也没有分配可用于 ACME 的公网测试域名。真实核心配置校验能够运行，但不能据此声称完成了一次真实 VPS 安装。

## GitHub Actions 发行版用户空间矩阵

`.github/workflows/ci.yml` 运行两个层次：

1. Ubuntu 24.04 runner 下载真实冻结核心并执行完整 `tests/run.sh`。
2. 8 个发行版镜像分别在 amd64 与 QEMU arm64 用户空间运行全部 Shell 语法解析、对应架构的真实 qrc、真实 `/etc/os-release` 平台检测，并实际渲染和结构化检查 IPv4-only、IPv6-only、dual 三种模式，共 16 个系统/架构组合；amd64 另外从缺少工具的镜像执行一次离线 Bootstrap，真实调用该发行版的包管理器。

矩阵目标：

| 发行版镜像 | amd64 | arm64/QEMU |
|---|---:|---:|
| Debian 12 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| Debian 13 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| Ubuntu 24.04 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| Ubuntu 26.04 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| Rocky Linux 9 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| Rocky Linux 10 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| AlmaLinux 9 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |
| AlmaLinux 10 | 平台 + 三模式渲染 | 平台 + 三模式渲染 |

Actions 使用固定 commit SHA 引用 checkout 与 QEMU action。矩阵状态以对应提交/PR 的 GitHub Checks 为准；工作流文件存在不等于某次提交已经通过。

## 手动完整 systemd VM 矩阵

`.github/workflows/vm-smoke.yml` 不在每个普通 PR 自动运行，只能手动触发，或在专用
`agent/vm-validation/**` 分支运行。它从 Debian、Ubuntu、Rocky Linux 与 AlmaLinux
官方站点下载云镜像并核对同站校验和，在 QEMU amd64 完整虚拟机中确认 PID 1 确实是
systemd，再运行平台识别、全部 Shell 语法、schema 4 四线路渲染、250 次 ACME 快速
失败、限额/超时保护、systemd unit 解析和实际临时 unit 启动。Debian 12 还会安装
固定版本且经过校验的 sing-box 与 Mihomo，使用生成的订阅对 TUIC、SS2022、AnyTLS、
AnyReality 和 Trojan 做 IPv4-only 与双栈域名往返；客户端位于独立 network namespace，入站
必须穿过由 Neko 配置且默认拒绝其他入站的 UFW。八个发行版 job 相互独立，单个失败
不会取消其他结果。

这个手动矩阵验证的是完整 systemd 用户空间与内核边界，不申请真实公网证书，也不
导入移动客户端；arm64 仍由上面的 16 组 QEMU user-mode 矩阵覆盖，不能把它描述成
arm64 完整 VM。某个 VM 工作流文件存在也不等于某次提交已经实际通过，应以对应
Actions run 为准。

## 仍未由隔离环境完成

以下项目需要真实、可重装的公网 VPS 与真机客户端：

- 8 个发行版各自使用真实公网 DNS/证书完成安装、重启、升级、失败回滚和卸载循环；
- 单栈/双栈活动 DNS 名称的真实 Let’s Encrypt 生产证书签发、面板 SAN 扩容及后续自动续期；
- Cloudflare 生产 API 对 Token 权限、TXT 传播和清理的真实端到端调用；
- 云厂商安全组、firewalld/UFW 与 Hysteria 端口跳跃在真实内核上的联动；
- 公网 IPv4/IPv6 路由、运营商 DNS64/NAT64、透明代理和地区性封锁行为；
- 真实公网 IP 的 Cloudflare 边缘位置/时延、RIPE RIS 公告与 RPKI API 返回，以及不同时间的 CPU/磁盘性能波动；
- Stash、Shadowrocket 与 sing-box 官方移动客户端真机导入，以及八种协议的延迟、吞吐、漫游和断线重连；
- iPad SSH 终端的真实二维码尺寸、截图后由“照片”识别，以及各客户端扫描导入；
- 非 443 REALITY 在具体网络中的可用性与封锁概率。

容器和 QEMU user-mode 很适合发现 Bash、架构、系统识别和配置格式问题；专用 QEMU
完整 VM 进一步覆盖真实 systemd，但仍不能代替公网 DNS、防火墙、ACME 与移动客户端
真机测试。首次部署应使用可随时重装的测试 VPS，导入当前 4 条或 16 条订阅逐项验收
后再长期使用。
