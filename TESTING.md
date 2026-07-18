# 测试报告

测试日期：2026-07-18（Asia/Tokyo）

## 已完成的检查

### 1. 发行版根文件系统矩阵

使用各发行版公开容器镜像导出根文件系统。amd64 通过原生 `chroot` 运行该发行版自带的 Bash；arm64 通过静态 QEMU user-mode 运行该发行版自带的 arm64 Bash。两种架构都执行了项目所有 Shell 文件的语法解析和 `detect_platform`。

| 系统镜像实际版本 | amd64 Bash | arm64 Bash/QEMU | 结果 |
|---|---:|---:|---|
| Debian 12 | 5.2.15 | 5.2.15 | 通过 |
| Debian 13 | 5.2.37 | 5.2.37 | 通过 |
| Ubuntu 24.04 | 5.2.21 | 5.2.21 | 通过 |
| Ubuntu 26.04 | 5.3.9 | 5.3.9 | 通过 |
| Rocky Linux 9.8 | 5.1.8 | 5.1.8 | 通过 |
| Rocky Linux 10.2 | 5.2.26 | 5.2.26 | 通过 |
| AlmaLinux 9.8 | 5.1.8 | 5.1.8 | 通过 |
| AlmaLinux 10.2 | 5.2.26 | 5.2.26 | 通过 |

此外，`tests/platform-matrix.sh` 对 8 个系统版本分别模拟 amd64/arm64，共 16 个允许组合，并验证 Ubuntu 22.04 等非目标版本会被拒绝。

### 2. 冻结资产与双架构核心

下载并验证了 `versions.env` 中全部 10 个服务端资产哈希（5 个组件 × 2 个架构）。

| 检查 | amd64 原生 | arm64 QEMU |
|---|---:|---:|
| Xray 26.3.27 版本及 `run -test` | 通过 | 通过 |
| sing-box 1.13.14 版本及 `check` | 通过 | 通过 |
| Caddy 2.11.4 版本及 `validate` | 通过 | 通过 |
| Hysteria 2.10.0 版本及配置解析 | 通过 | 通过 |
| lego 5.2.2 版本及 v5 `run` CLI 参数 | 通过 | 通过 |

Hysteria 没有独立的“只校验”命令。测试将 `PATH` 指向空目录后启动生成配置，确认 YAML 已被读取并运行到端口跳跃帮助程序的查找阶段；随后按预期停止，从而避免修改测试宿主的防火墙。证书、认证和混淆字段另由结构化 YAML 断言检查。

### 3. 配置和订阅

- ShellCheck 0.11.0：通过（排除动态 source、跨文件全局变量和 jq 单引号表达式等有意用法）。
- Bash `-n`：全部脚本通过。
- Bootstrap：离线打包并解压固定 1.0.4 源码，校验必需文件、版本标记和临时目录清理；交互安装仍由同一 `install.sh` 执行。
- 随机端口分配：连续运行 50 轮；128 个 Hysteria2 端口与其余五个端口均无冲突。
- Mihomo 1.19.28：实际执行 `mihomo -t`，6 节点配置通过。
- Stash：按官方字段生成 5 节点配置；确认 Hysteria2 使用 `auth`、TUIC 使用 `version: 5`，且不存在 XHTTP。
- Shadowrocket：结构化 YAML 严格为 6 个节点；连接地址使用状态中固定的 IP，TLS SNI、REALITY serverName 与 XHTTP Host 保留绑定域名。测试覆盖 IPv4 优先、纯 IPv6 回退、SS2022 编码/DNS 对照诊断、六协议直连诊断和原地升级清理。
- REALITY：两个入站都指向 `127.0.0.1:8443`，`serverNames` 为绑定域名。
- 证书：TUIC、AnyTLS、Hysteria2、Caddy 都引用同一 lego 证书；REALITY 的回环目标也加载该证书。
- 令牌轮换：重新渲染后 Caddyfile 只包含新令牌，旧路径不存在。
- systemd：6 个单元通过 systemd 255 的 `systemd-analyze verify`；同时检查 Hysteria CAP_NET_ADMIN、sing-box AF_NETLINK 与续期写路径。

### 4. 当前 Ubuntu 24.04 环境

开发环境的用户空间是 Ubuntu 24.04，Xray 配置曾直接启动并保持运行到测试超时。该环境限制了 netlink、PID 1 不是 systemd，且不提供完整公网域名，因此没有把它描述成一次真实 VPS 安装。

### 5. 公网 VPS 与真机客户端复测

在一台 AlmaLinux 9 amd64 公网 VPS 上完成真实证书签发和服务启动。Mihomo 内核应用的六个节点均可导入并使用。Shadowrocket 2.2.90 的对照测试显示：相同 SS2022 参数使用域名时请求未到达服务器，改用域名解析出的直连 IPv4 后立即正常；随后保持全部 SNI/证书/REALITY 域名字段不变，仅把六个节点的连接地址改为该 IPv4，Hysteria2、TUIC v5、SS2022、AnyTLS、VLESS REALITY Vision 和 VLESS REALITY XHTTP 均测出延迟并可使用。

这次实测支持 1.0.4 的 Shadowrocket 专用直连地址策略，但它只代表该 VPS、客户端版本和当时网络，不能替代所有地区、运营商与双栈组合的长期测试。

## 没有声称完成的测试

以下项目必须在用户自己的公网 VPS、域名和客户端上完成，当前隔离环境无法诚实替代：

- 真实 Let’s Encrypt 生产证书签发与数月后的自动续期；
- 8 个发行版各自作为完整 systemd 虚拟机的开机、重启和卸载循环；
- 云厂商安全组、NAT、IPv6 路由与地区性网络封锁行为；
- Stash 真机导入，以及各客户端六种协议的长期吞吐、漫游和断线重连测试；
- 非 443 REALITY 在特定网络环境中的封锁概率。

容器根文件系统和 QEMU 测试能发现架构、Bash、系统识别及核心配置问题，但不能冒充完整 VM 或真机网络测试。建议首次在一台可随时重装的 VPS 上部署，逐个客户端验证后再用于长期节点。
