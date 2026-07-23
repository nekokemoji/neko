# Neko 1.2.3 测试范围

最近核对日期：2026-07-24（Asia/Tokyo）。

这份文件把“已经由自动测试验证的内容”和“必须在真实 VPS/客户端验证的内容”分开，避免把容器或静态检查描述成完整系统实装。

## 本地核心测试

执行方式：

```bash
bash tests/fetch-pinned-tools.sh
bash tests/run.sh
```

`tests/fetch-pinned-tools.sh` 从上游精确 release tag 下载测试二进制并校验 `versions.env` 中固定的 SHA-256。`tests/run.sh` 当前覆盖：

- 所有 Shell 文件通过 `bash -n` 与 ShellCheck；缺少 ShellCheck 或 PyYAML 时测试失败而不是跳过。
- `detect_platform` 模拟 Debian 12/13、Ubuntu 24.04/26.04、Rocky 9/10、AlmaLinux 9/10 的 amd64/arm64，共 16 个允许组合，并验证不支持版本会被拒绝。
- Debian 与 RHEL 两条依赖安装分支使用 mock 调用验证。
- 严格 DNS 正例通过；所有域名查询都使用末尾点号避免系统 DNS search 后缀污染；`v4` 名称带 AAAA、`v6` 名称带 A 等错误配置会失败。
- firewalld 根据 IPv4/IPv6 默认路由网卡寻找实际 zone，而不是盲目使用 default zone。
- Bootstrap 离线解压固定源码包、核对 1.2.3 标记并清理临时目录；模拟精简系统缺少 `tar`/`gzip` 时会先通过系统包管理器补齐。
- 所有发行版容器都用各自真实的 `awk` 解析模拟 DNS 结果；其中 Debian 12 的旧版 mawk 不支持正则区间表达式，测试会确认严格 IPv4 解析不依赖该语法。
- HTTP-01 在签发前为 firewalld/UFW 临时放行 TCP 80，并在完成后只删除本次创建的临时规则；firewalld 规则带自动过期保护。
- Xray 26.3.27、sing-box 1.13.14、Hysteria 2.10.0、Caddy 2.11.4、lego 5.2.2 和 Mihomo 1.19.29 的版本身份与 CLI 参数。
- Cloudflare DNS-01 与 HTTP-01 分别传递正确的 lego 参数；DNS-01 只暴露固定的 `_FILE` 凭据变量，清除原始 Token、旧式变量和外部文件变量。
- Cloudflare Token 内容格式、凭据目录 `0700`、文件 `0600` 与非符号链接约束。
- 真实 `sing-box check`、`xray run -test`、`caddy validate`。
- Hysteria 的 IPv4/IPv6 两份配置分别读取并执行到端口跳跃帮助程序查找阶段；测试刻意不给它 nftables/iptables，避免改动宿主防火墙。
- 真实 Mihomo 分别解析严格 IPv4 与严格 IPv6 配置。
- 订阅目录恰好生成 6 个文件：Mihomo、Stash、Shadowrocket 各 v4/v6 两份。
- Mihomo 6 个节点全部使用对应 IP 字面量和 `ip-version`；Stash 5 个节点全部使用对应 IP；Shadowrocket 6 个节点全部使用对应 IP。
- Mihomo TUIC 明确包含 TLS SNI；其余证书主机名、REALITY `serverName` 与 XHTTP Host 也保持基础域名，不被 IP 字面量替换。
- Caddy 只在 v4 主机发布 v4 文件、只在 v6 主机发布 v6 文件，并禁用公网 HTTP/3。
- sing-box 的六个入站与 Xray 的四个入站按本机 IPv4/IPv6 地址分开监听；sing-box 在路由阶段按入口只解析同族地址、拒绝异族 IP 字面量，再进入同族源地址绑定出口。
- Hysteria 两份配置分别使用 `mode: 4`/`mode: 6` 和 `bindIPv4`/`bindIPv6`；用假核心动态验证监管脚本会同时启动两族，并在任一子进程退出时终止另一进程，交由 systemd 重启。
- 三个服务端核心都阻断私有/回环/链路本地地址和 TCP 25；Xray、sing-box 配置由真实核心校验，Hysteria ACL 与同族 direct 出站由配置加载路径和结构化断言校验。
- 随机端口连续运行 50 轮：Hysteria2 的 128 端口区间与其余五个单端口无冲突。
- 订阅令牌轮换后旧路径从 Caddy 配置消失。
- 控制面板端点刷新在地址未变化时不重启；模拟新地址更新成功、服务失败后完整回滚，以及回滚服务仍失败时保留状态备份。
- 分别从 schema 1 / Neko 1.0.x 和 schema 2 / Neko 1.1.x 模拟升级到 Neko 1.2.3，确认端口、协议凭据、REALITY 参数和订阅令牌不变，旧订阅文件被替换为 6 个新文件，并安装 Hysteria 双进程监管脚本与单元。
- 模拟升级中 Caddy 重启失败，确认状态、配置、Hysteria systemd 单元恢复，新增监管脚本移除，临时备份清理。
- systemd 单元的关键沙箱、能力与续期写路径静态断言。

本次修改在当前 Ubuntu 24.04 用户空间中完成；这里 PID 1 不是 systemd，也没有分配可用于 ACME 的公网双栈域名。真实核心配置校验能够运行，但不能据此声称完成了一次真实 VPS 安装。

## GitHub Actions 发行版用户空间矩阵

`.github/workflows/ci.yml` 运行两个层次：

1. Ubuntu 24.04 runner 下载真实冻结核心并执行完整 `tests/run.sh`。
2. 8 个发行版镜像分别在 amd64 与 QEMU arm64 用户空间运行全部 Shell 语法解析和真实 `/etc/os-release` 平台检测，共 16 个组合；amd64 另外从缺少工具的镜像执行一次离线 Bootstrap，真实调用该发行版的包管理器。

矩阵目标：

| 发行版镜像 | amd64 | arm64/QEMU |
|---|---:|---:|
| Debian 12 | 检查 | 检查 |
| Debian 13 | 检查 | 检查 |
| Ubuntu 24.04 | 检查 | 检查 |
| Ubuntu 26.04 | 检查 | 检查 |
| Rocky Linux 9 | 检查 | 检查 |
| Rocky Linux 10 | 检查 | 检查 |
| AlmaLinux 9 | 检查 | 检查 |
| AlmaLinux 10 | 检查 | 检查 |

Actions 使用固定 commit SHA 引用 checkout 与 QEMU action。矩阵状态以对应提交/PR 的 GitHub Checks 为准；工作流文件存在不等于某次提交已经通过。

## 仍未由隔离环境完成

以下项目需要真实、可重装的公网 VPS 与真机客户端：

- 8 个发行版各自作为完整 systemd VM 的安装、重启、升级、失败回滚和卸载循环；
- 三个 DNS 名称的真实 Let’s Encrypt 生产证书签发及后续自动续期；
- Cloudflare 生产 API 对 Token 权限、TXT 传播和清理的真实端到端调用；
- 云厂商安全组、firewalld/UFW 与 Hysteria 端口跳跃在真实内核上的联动；
- 公网 IPv4/IPv6 路由、运营商 DNS64/NAT64、透明代理和地区性封锁行为；
- Stash 与 Shadowrocket 真机导入，以及六种协议的延迟、吞吐、漫游和断线重连；
- 非 443 REALITY 在具体网络中的可用性与封锁概率。

容器和 QEMU user-mode 很适合发现 Bash、架构、系统识别和配置格式问题，但不能代替 systemd、内核网络、防火墙、ACME 与移动客户端真机测试。首次部署应使用可随时重装的测试 VPS，导入六条订阅逐项验收后再长期使用。
