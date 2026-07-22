# Neko 1.1.0 测试范围

最近核对日期：2026-07-23（Asia/Tokyo）。

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
- 严格 DNS 正例通过；`v4` 名称带 AAAA、`v6` 名称带 A 等错误配置会失败。
- firewalld 根据 IPv4/IPv6 默认路由网卡寻找实际 zone，而不是盲目使用 default zone。
- Bootstrap 离线解压固定源码包、核对 1.1.0 标记并清理临时目录。
- Xray 26.3.27、sing-box 1.13.14、Hysteria 2.10.0、Caddy 2.11.4、lego 5.2.2 和 Mihomo 1.19.29 的版本身份与 CLI 参数。
- 真实 `sing-box check`、`xray run -test`、`caddy validate`。
- Hysteria 读取配置并执行到端口跳跃帮助程序查找阶段；测试刻意不给它 nftables/iptables，避免改动宿主防火墙。
- 真实 Mihomo 分别解析严格 IPv4 与严格 IPv6 配置。
- 订阅目录恰好生成 6 个文件：Mihomo、Stash、Shadowrocket 各 v4/v6 两份。
- Mihomo 6 个节点全部使用对应 IP 字面量和 `ip-version`；Stash 5 个节点全部使用对应 IP；Shadowrocket 6 个节点全部使用对应 IP。
- TLS SNI、证书主机名、REALITY `serverName` 与 XHTTP Host 保持基础域名，不被 IP 字面量替换。
- Caddy 只在 v4 主机发布 v4 文件、只在 v6 主机发布 v6 文件，并禁用公网 HTTP/3。
- 三个服务端核心都阻断私有/回环/链路本地地址和 TCP 25；Xray、sing-box 配置由真实核心校验，Hysteria ACL 由配置加载路径与结构化断言校验。
- 随机端口连续运行 50 轮：Hysteria2 的 128 端口区间与其余五个单端口无冲突。
- 订阅令牌轮换后旧路径从 Caddy 配置消失。
- 从 schema 1 / Neko 1.0.x 模拟升级到 schema 2 成功，旧订阅文件被替换为 6 个新文件。
- 模拟升级中 Caddy 重启失败，确认状态与配置哈希恢复、临时备份清理。
- systemd 单元的关键沙箱、能力与续期写路径静态断言。

本次修改在当前 Ubuntu 24.04 用户空间中完成；这里 PID 1 不是 systemd，也没有分配可用于 ACME 的公网双栈域名。真实核心配置校验能够运行，但不能据此声称完成了一次真实 VPS 安装。

## GitHub Actions 发行版用户空间矩阵

`.github/workflows/ci.yml` 运行两个层次：

1. Ubuntu 24.04 runner 下载真实冻结核心并执行完整 `tests/run.sh`。
2. 8 个发行版镜像分别在 amd64 与 QEMU arm64 用户空间运行全部 Shell 语法解析和真实 `/etc/os-release` 平台检测，共 16 个组合。

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
- 云厂商安全组、firewalld/UFW 与 Hysteria 端口跳跃在真实内核上的联动；
- 公网 IPv4/IPv6 路由、运营商 DNS64/NAT64、透明代理和地区性封锁行为；
- Stash 与 Shadowrocket 真机导入，以及六种协议的延迟、吞吐、漫游和断线重连；
- 非 443 REALITY 在具体网络中的可用性与封锁概率。

容器和 QEMU user-mode 很适合发现 Bash、架构、系统识别和配置格式问题，但不能代替 systemd、内核网络、防火墙、ACME 与移动客户端真机测试。首次部署应使用可随时重装的测试 VPS，导入六条订阅逐项验收后再长期使用。
