# Feilian CPE 健康巡检工具使用说明

本文档面向初级使用者，说明 `scripts/feilian-cpe-health-check-pro.sh` 的安装、运行、菜单功能、输出含义、每个巡检项的作用，以及常见优化脚本的使用注意事项。

## 1. 工具简介

`feilian-cpe-health-check-pro.sh` 是一个 Bash 脚本，用于在飞连 SD-WAN CPE 设备或相关 Linux 环境上进行巡检、排障和常见优化。

它可以帮助你完成这些事情：

- 查看 CPE 设备整体健康状态。
- 排查某个目标 IP 的 IP 调度是否生效。
- 排查某个域名的域名调度是否生效。
- 检查 WireGuard 隧道状态、POP 延迟和隧道质量。
- 执行常见优化动作，例如重新选择 POP、固定 POP、默认路由入口策略、TCP 透明代理。

脚本位置：

```bash
scripts/feilian-cpe-health-check-pro.sh
```

## 2. 适用对象

适合以下人员使用：

- CPE 设备运维人员。
- 交付工程师。
- 网络故障排查人员。
- 刚接触飞连 CPE 排障的新手。

如果你不熟悉 Linux，也可以按照本文档中的命令一步一步执行。

## 3. 运行前准备

### 3.1 建议使用 root 权限

很多检查项需要读取系统服务、iptables、路由表、CPE 配置和日志。建议使用 `root` 或 `sudo` 执行。

```bash
sudo -s
```

或直接：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh
```

### 3.2 给脚本增加执行权限

第一次使用前执行：

```bash
chmod +x scripts/feilian-cpe-health-check-pro.sh
```

### 3.3 依赖命令说明

脚本会尽量兼容系统已有命令，部分功能会使用以下命令：

- `systemctl`：查看和管理系统服务。
- `ip`：查看路由、策略路由和网卡。
- `iptables`：查看和维护 NAT 透明代理规则。
- `ss`：检查端口监听。
- `curl`：检查管理平台、GRPC、DNS 等连通性。
- `dig`：检查 DNS 解析。
- `traceroute`：检查数据面转发路径。
- `jq`：美化 JSON 日志输出，不存在时会降级显示原始日志。
- `nginx`：仅 TCP 透明代理优化功能需要。

如果某些命令不存在，脚本通常会给出提示，不一定会中断全部巡检。

## 4. 快速开始

### 4.1 进入交互菜单

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh
```

进入菜单后会看到：

```text
1. CPE巡检
2. CPE IP发布检查
3. CPE 域名调度检查
4. CPE常见优化脚本
```

直接回车不会默认选择，会保持当前菜单继续等待输入。

### 4.2 直接执行全面巡检

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe
```

### 4.3 排查 IP 调度

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode ip --target-ip 203.0.113.10
```

指定检查接口，默认是 `tun0_master`：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode ip --target-ip 203.0.113.10 --iface tun0_master
```

### 4.4 排查域名调度

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode domain --domain www.aliyun.com
```

### 4.5 进入优化脚本菜单

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode optimize
```

### 4.6 保存文本报告

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe -f -o /tmp/feilian-cpe-report.txt
```

### 4.7 输出 JSON 摘要

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe -j
```

保存 JSON：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe -j -o /tmp/feilian-cpe-report.json
```

## 5. 命令行参数说明

| 参数 | 说明 | 示例 |
|---|---|---|
| `-h` 或 `--help` | 查看帮助信息 | `./scripts/feilian-cpe-health-check-pro.sh --help` |
| `--mode cpe` | 直接执行 CPE 全面巡检 | `--mode cpe` |
| `--mode ip` | 直接执行 IP 调度排查 | `--mode ip --target-ip 203.0.113.10` |
| `--mode domain` | 直接执行域名调度排查 | `--mode domain --domain www.aliyun.com` |
| `--mode optimize` | 进入常见优化脚本菜单 | `--mode optimize` |
| `--target-ip IP` | IP 调度排查目标 IP | `--target-ip 203.0.113.10` |
| `--domain DOMAIN` | 域名调度排查目标域名 | `--domain www.aliyun.com` |
| `--iface IFACE` | IP 调度排查接口，默认 `tun0_master` | `--iface tun0_master` |
| `-f` 或 `--full` | 展示全部巡检项，不跳过重复项 | `-f` |
| `-j` 或 `--json` | 输出 JSON 摘要 | `-j` |
| `-o FILE` 或 `--output FILE` | 保存报告到文件 | `-o /tmp/report.txt` |
| `-q` 或 `--quiet` | 安静模式，减少输出 | `-q` |
| `--no-color` | 禁用彩色输出，便于复制或重定向 | `--no-color` |

## 6. 交互规则

### 6.1 菜单选择

菜单中直接回车表示保持当前菜单，不会返回，也不会默认选择。

示例：

```text
请选择操作 [0-3，直接回车保持当前菜单]:
```

如果直接回车，脚本会继续显示当前菜单。

### 6.2 确认执行

涉及修改系统配置的动作都会二次确认。

确认规则：

- 输入 `y` 或 `Y`：确认执行。
- 直接回车：保持当前确认项，继续等待输入。
- 输入其他任意内容：取消执行。

示例：

```text
输入 y/Y 确认执行，直接回车保持当前确认项，输入其他任意内容取消:
```

### 6.3 IP 输入

脚本会自动去掉 IP 前后的空格。例如：

```text
203.0.113.10<尾随空格>
```

会被识别为：

```text
203.0.113.10
```

## 7. 输出结果怎么看

每个巡检项通常包含这些内容：

| 字段 | 含义 |
|---|---|
| `检查项` | 当前检查的名称。 |
| `检查要求` | 这个检查希望满足的标准。 |
| `使用命令` | 脚本实际执行或等价展示的命令。 |
| `回显结果` | 命令输出或脚本整理后的结果。 |
| `巡检结果` | 通过、警告或失败。 |
| `判断原因` | 为什么通过、为什么警告、为什么失败。 |
| `优化建议` | 出现异常时建议优先检查的方向。 |

结果标识：

- `通过`：当前检查满足预期。
- `警告`：存在风险或无法完全确认，但不一定代表故障。
- `失败`：检查不满足预期，需要处理。

## 8. 主菜单功能总览

### 8.1 选项 1：CPE巡检

用于全面检查 CPE 健康状态，适合这些场景：

- 设备刚上线，需要确认基础状态。
- 用户反馈访问异常，需要先做整体健康检查。
- 排障前需要生成一份完整报告。
- 变更后需要确认服务、隧道、路由和 DNS 是否正常。

执行方式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe
```

### 8.2 选项 2：CPE IP发布检查

用于排查某个目标 IP 的 IP 调度是否生效。

适合这些场景：

- 访问某个 IP 没有走飞连隧道。
- IP 调度规则下发后不生效。
- 想确认目标 IP 的路由、调度、下车 CPE 和 traceroute 是否一致。

执行方式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode ip --target-ip 203.0.113.10
```

### 8.3 选项 3：CPE 域名调度检查

用于排查某个域名的域名调度是否生效。

适合这些场景：

- 域名策略已配置但访问没有按预期调度。
- 需要确认 dnsmasq 是否命中域名规则。
- 需要确认 forwarded DNS 是否和配置一致。
- 需要确认域名解析出的首个 IP 是否命中域名调度。

执行方式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode domain --domain www.aliyun.com
```

### 8.4 选项 4：CPE常见优化脚本

用于执行会修改系统配置的优化动作。

进入方式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode optimize
```

注意：优化脚本会修改服务、路由、iptables 或配置文件。执行前请认真阅读脚本展示的风险提示和将执行动作。

## 9. CPE 全面巡检功能详解

### 9.1 操作系统与内核版本

检查内容：

- 操作系统发行版。
- 内核版本。
- 主机名。
- 运行时间。

作用：帮助确认设备运行环境，判断系统版本是否符合预期。

### 9.2 系统性能检查

检查内容：

- CPU 负载。
- 内存使用情况。
- 磁盘空间。
- 进程数量。

作用：判断是否因资源不足导致 CPE 服务异常。

### 9.3 本地时间同步状态

检查内容：

- 本地时间。
- 时区。
- 与服务端时间偏差。

作用：时间偏差过大可能导致证书、鉴权、日志分析异常。

### 9.4 所有网络接口状态

检查内容：

- 网卡 UP/DOWN 状态。
- IP 地址。
- 接口基本信息。

作用：确认物理网卡、隧道接口是否存在且状态正常。

### 9.5 iptables 防火墙状态与策略

检查内容：

- iptables 规则。
- 默认策略。
- NAT 表状态。

作用：判断防火墙是否影响转发、NAT 或透明代理。

### 9.6 ufw 防火墙状态

检查内容：

- `ufw` 是否启用。
- 当前规则。

作用：Ubuntu 系统中 `ufw` 可能拦截流量。

### 9.7 firewalld 服务状态

检查内容：

- `firewalld` 是否运行。
- 当前区域和规则。

作用：CentOS/RHEL/Rocky 系统中 `firewalld` 可能影响转发。

### 9.8 nftables 状态

检查内容：

- `nftables` 是否启用。
- 当前 nft 规则。

作用：部分系统使用 nftables 替代 iptables。

### 9.9 SELinux 状态

检查内容：

- SELinux 当前模式。

作用：SELinux enforcing 可能影响服务访问文件、端口或网络。

### 9.10 IP 转发功能

检查内容：

- `net.ipv4.ip_forward` 是否开启。

作用：CPE 转发流量通常需要开启 IP 转发。

### 9.11 TCP 拥塞控制算法

检查内容：

- 当前 TCP 拥塞控制算法。
- 可用拥塞控制算法。

作用：辅助判断 TCP 性能配置。

### 9.12 连接跟踪表配置

检查内容：

- nf_conntrack 当前使用量。
- nf_conntrack 最大值。

作用：连接跟踪表满了会导致新连接失败。

### 9.13 TCP 缓冲区配置

检查内容：

- TCP 读写缓冲参数。
- 系统网络缓冲配置。

作用：辅助判断吞吐和性能问题。

### 9.14 CPE 版本信息

检查内容：

- 飞连 CPE 版本。
- 相关组件版本。

作用：确认当前运行版本，便于和已知问题、升级记录匹配。

### 9.15 CPE 服务运行状态检查

检查内容：

- `feilian-cpe` 服务状态。
- `feilian-tun@tun0_master` 状态。
- `feilian-tun@tun0_slave` 状态。
- 其他关键服务状态。

作用：确认核心服务是否 active。

### 9.16 执行 CPE 网络健康检查脚本

检查内容：

- 调用 CPE 自带健康检查能力。
- 展示官方检查输出。

作用：快速获取官方健康检查结果。

### 9.17 CPE 事件 ERROR 日志检查

检查内容：

- `/opt/feilian/cpe/log/cpe.event.log` 中的 ERROR 日志。

作用：定位服务异常、注册失败、隧道异常等问题。

### 9.18 Panic 崩溃日志检查

检查内容：

- 是否存在 panic 或 crash 日志。

作用：判断是否出现程序崩溃。

### 9.19 默认网关连通性

检查内容：

- 默认网关地址。
- ping 默认网关。

作用：确认 CPE 到本地出口网关是否通。

### 9.20 DNS 解析与连通性检查

检查内容：

- DNS 配置。
- DNS 解析是否成功。
- 出接口信息。

作用：判断域名解析和基础外网连通性。

### 9.21 连接管理后台

检查内容：

- 管理平台 HTTPS 连通性。
- token 接口返回状态。

作用：判断 CPE 是否能访问飞连管理后台。

### 9.22 连接管理后台 GRPC

检查内容：

- 获取 访问凭据。
- 连接管理后台 GRPC 地址。

作用：判断 CPE 和管理后台 GRPC 通道是否正常。

### 9.23 连接中心 DNS GRPC

检查内容：

- 获取 访问凭据。
- 连接中心 DNS GRPC 地址。

作用：判断 CPE 到中心 DNS 控制面的 GRPC 通道是否正常。

### 9.24 中心 DNS UDP 端口探测

检查内容：

- 中心 DNS 地址。
- UDP 443 DNS 探测。

作用：判断中心 DNS 数据面是否可达。

### 9.25 POP 节点探测（主备）

检查内容：

- 主 POP 和备 POP 地址。
- POP 探测结果。

作用：判断 CPE 到 POP 节点连通性和延迟情况。

### 9.26 隧道连通性（主备）

检查内容：

- 主备隧道连通性。
- 隧道接口状态。

作用：确认飞连隧道是否可用。

### 9.27 WireGuard 隧道详细状态

检查内容：

- `feilian-tun-cli` 输出。
- peer、endpoint、latest handshake、transfer 等信息。

作用：判断 WireGuard 隧道是否正常握手和收发流量。

### 9.28 WireGuard 隧道配置一致性与所有 POP 延迟信息

检查内容：

- `feilian-tun-ctrl` 相关配置。
- 所有 POP 延迟信息。
- 主备接口配置一致性。

作用：判断本地隧道配置和 POP 信息是否符合预期。

### 9.29 WireGuard 隧道质量检测

检查内容：

- 通过 `feilian-tun-ctrl show -i tun0_master measure` 获取质量数据。
- 计算 RTT、抖动、丢包、发送流量、接收流量。
- 输出质量评级。

质量评级参考：

| 等级 | 含义 |
|---|---|
| 最优 | RTT、抖动、丢包都非常好，适合作为主业务链路。 |
| 优秀 | 链路质量良好，可以稳定承载业务。 |
| 良好 | 链路达标，一般业务无明显感知。 |
| 异常 | RTT 高、抖动大、持续丢包、无接收流量或离线，需要排查。 |

## 10. IP 调度排查详解

IP 调度排查用于确认目标 IP 是否按预期进入飞连隧道，并命中正确的下车 CPE。

### 10.1 输入目标 IP

交互模式会提示：

```text
请输入待验证目标IP:
```

命令行模式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode ip --target-ip 203.0.113.10
```

### 10.2 步骤 2：路由走向校验

检查内容：

- 执行 `ip route get <目标IP>`。
- 判断目标 IP 是否走 `tun0_master` 或 `tun0_slave`。
- 展示路由表信息。

通过标准：目标 IP 应进入飞连隧道路径。

异常处理：如果目标 IP 走物理网卡或 main 表，需要检查策略路由和飞连路由下发。

### 10.3 步骤 3：调度规则匹配校验

检查内容：

- 执行 `feilian-tun-ctrl show -i tun0_master dispatch`。
- 判断目标 IP 是否命中 IP 调度规则。
- 如果命中域名调度，会提示反查域名来源。
- 读取 `/opt/feilian/cpe/conf/dispatch_priority.json`，显示调度优先级配置。

调度优先级说明：

| 配置值 | 含义 |
|---|---|
| `dispatch_priority=1` | `DispatchSaas`，域名调度优先。 |
| `dispatch_priority=0` | `DispatchIP`，IP 调度优先。 |

通过标准：目标 IP 命中预期 IP 调度规则，并能看到预期下车 CPE 隧道 IP。

### 10.4 步骤 4：数据面转发验证

检查内容：

- 对目标 IP 执行 traceroute。
- 解析第二跳 IP。
- 和调度规则中的下车 CPE 隧道 IP 对比。

通过标准：traceroute 第二跳应为调度规则中的下车 CPE 隧道 IP。

异常处理：如果第二跳不一致，需要检查 DNAT 规则、策略下发和下车 CPE 连通性。

## 11. 域名调度排查详解

域名调度排查用于确认目标域名是否被 dnsmasq 命中、是否转发到正确 DNS、解析 IP 是否命中域名调度。

### 11.1 输入目标域名

命令行模式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode domain --domain www.aliyun.com
```

### 11.2 步骤 2：域名调度列表匹配

检查内容：

- 读取 `/etc/dnsmasq.d/gfw_domain.conf`。
- 查找 `server=/域名/上游DNS#端口` 规则。
- 支持精确匹配和子域名后缀匹配。
- 不支持 `*` 通配。

通过标准：目标域名应命中域名调度规则。

### 11.3 步骤 3：feilian-dnsmasq 运行状态及端口检查

检查内容：

- `feilian-dnsmasq` 服务是否 active。
- 进程是否存在。
- 53 端口是否监听。

通过标准：服务、进程和监听端口均正常。

### 11.4 步骤 4：DNS 解析验证

检查内容：

- 执行 `dig <域名> @127.0.0.1`。
- 绑定所有非隧道、非 Docker 的 UP 物理接口源 IP 再解析一次。

通过标准：本机 DNS 代理能解析出 A 记录。

### 11.5 步骤 5：dnsmasq 解析日志检查

检查内容：

- 读取 `/opt/feilian/cpe/log/dnsmasq.query.log*`。
- 按目标域名过滤日志。
- 展示 `query[A]`、`forwarded`、`reply`、`cached` 等记录。
- 如果存在 `forwarded <domain> to <DNS>`，会提取实际上游 DNS。
- 对比实际 forwarded DNS 和 `gfw_domain.conf` 中配置的 DNS 是否一致。

通过标准：日志中能看到目标域名解析记录；如存在 forwarded，上游 DNS 应与配置一致。

### 11.6 步骤 6：解析 IP 调度命中分析

检查内容：

- 获取目标域名首个 A 记录。
- 查看该 IP 是否命中域名调度规则。
- 展示预期下车 CPE 隧道 IP。
- 展示 `dispatch_priority.json` 配置值和运行态是否一致。

通过标准：域名首个 A 记录命中域名调度，并能看到预期下车 CPE 隧道 IP。

### 11.7 步骤 7：数据面转发验证

检查内容：

- 对域名首个 A 记录执行 traceroute。
- 解析第二跳。
- 和域名调度规则中的下车 CPE 隧道 IP 对比。

通过标准：第二跳应为域名调度规则中的下车 CPE 隧道 IP。

## 12. 常见优化脚本详解

进入方式：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode optimize
```

优化菜单包含：

```text
1. 清理已有的POP连接信息，重新选择POP点连接
2. 将自动选点修改为固定POP点
3. 默认路由入口流量强制从默认路由口出
4. TCP透明代理(iptables REDIRECT + Nginx stream)
0. 返回/退出
```

所有优化动作都会先展示用途、风险和将执行的命令。只有输入 `y` 或 `Y` 才会真正执行。

### 12.1 优化 1：清理已有 POP 连接信息，重新选择 POP 点连接

适用场景：

- CPE 当前 POP 连接异常。
- 想让 CPE 重新自动选择 POP。
- 固定 POP 配置需要清理并恢复自动选点。

会执行的动作：

- 停止 `feilian-cpe` 服务。
- 备份 `/opt/feilian/cpe/.cache/ucistore`。
- 删除 `master_tunnel`、`slave_tunnel` 缓存。
- 如果存在固定 POP 配置，会备份 `/opt/feilian/cpe/conf/cpe.env`。
- 删除 `SPECIFIC_MASTER_POP_SERVER` 和 `SPECIFIC_SLAVE_POP_SERVER`。
- 重启 `feilian-cpe`。
- 重启 `feilian-tun@tun0_master` 和 `feilian-tun@tun0_slave`。
- 观察 `cpe.event.log` 最新日志。
- 展示 `feilian-tun-cli` 最新连接信息。

风险说明：执行期间业务可能短暂中断。

### 12.2 优化 2：将自动选点修改为固定 POP 点

适用场景：

- 已确认主 POP 和备 POP IP。
- 希望 CPE 固定连接到指定 POP。

输入内容：

- 固定主 POP IP。
- 固定备 POP IP。

会执行的动作：

- 停止 `feilian-cpe` 服务。
- 清理 `already_report_environment` 缓存。
- 修改 `/opt/feilian/cpe/conf/cpe.env`。
- 写入 `SPECIFIC_MASTER_POP_SERVER=<主POP IP>`。
- 写入 `SPECIFIC_SLAVE_POP_SERVER=<备POP IP>`。
- 重启 `feilian-cpe`。
- 观察日志并展示最新连接信息。

恢复自动选点方法：删除 `cpe.env` 中的 `SPECIFIC_MASTER_POP_SERVER` 和 `SPECIFIC_SLAVE_POP_SERVER` 后重启 `feilian-cpe`。

### 12.3 优化 3：默认路由入口流量强制从默认路由口出

适用场景：

- 默认路由口既承载普通外网出口，又存在飞连隧道策略路由。
- 从默认路由口进入的回程流量被策略路由吸入隧道。
- 希望从默认路由口进入的流量仍从默认路由口出去。

会执行的动作：

- 自动识别非隧道默认路由口，例如 `eth0`。
- 检查是否已有类似策略路由。
- 如果没有，新增：

```bash
ip rule add pref <优先级> iif <默认路由口> lookup main
```

- 执行：

```bash
ip route flush cache
```

- 写入持久化脚本：

```text
/usr/local/sbin/feilian-default-ingress-main-route.sh
```

- 写入 systemd 服务：

```text
/etc/systemd/system/feilian-default-ingress-main-route.service
```

- 启用开机自动恢复，避免重启后丢失。

### 12.4 优化 4：TCP 透明代理

用于将从 `tun0_master` 或 `tun0_slave` 隧道进入、目标为指定 IP 和 TCP 端口的流量重定向到本地 Nginx stream，再由 Nginx 代理到原始目标。

适用场景：

- 某些 TCP 服务需要通过 CPE 做透明代理。
- 只希望代理隧道入站流量，不影响公网入口和其他业务。

管理菜单：

```text
1. 检查现有配置
2. 追加透明代理配置
3. 删除透明代理配置
0. 返回/退出
```

#### 12.4.1 检查现有配置

会展示：

- 已配置规则。
- 本地监听端口冲突检查。
- 规则文件状态。
- Nginx 配置文件状态。
- iptables 持久化脚本状态。
- systemd 服务状态。
- `FEILIAN_T_PROXY` iptables 链。
- 完整 Nginx stream 配置。

#### 12.4.2 追加透明代理配置

输入内容：

- 透明代理目标 IP，例如 `198.51.100.10`。
- 透明代理目标端口，例如 `23`。
- 多个端口用英文逗号分隔，例如 `995,587`。

不需要输入本地端口。本地端口会从 `20000` 开始自动分配。

示例：

```text
请输入透明代理目标IP: 198.51.100.10
请输入透明代理目标端口，多个用逗号分隔: 23,443
```

脚本可能生成：

```text
198.51.100.10:23 -> 127.0.0.1:20000
198.51.100.10:443 -> 127.0.0.1:20001
```

端口分配规则：

- 从 `20000` 开始找可用端口。
- 如果已有规则占用，会跳过。
- 如果系统已有服务监听，会跳过。
- 同一次输入多个目标端口，会分配不同本地端口。
- 目标端口重复会提示错误。

会写入的文件：

```text
/etc/feilian-tcp-transparent-proxy.rules
/etc/nginx/feilian-tcp-transparent-proxy.conf
/usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh
/etc/systemd/system/feilian-tcp-transparent-proxy-nginx.service
/etc/systemd/system/feilian-tcp-transparent-proxy-iptables.service
```

iptables 逻辑：

- 使用脚本专用链 `FEILIAN_T_PROXY`。
- `PREROUTING` 跳转到 `FEILIAN_T_PROXY`。
- 只匹配 `-i tun0_master` 和 `-i tun0_slave`。
- 只匹配指定目标 IP 和 TCP 目标端口。
- 命中后 `REDIRECT --to-ports <本地端口>`。

这样不会清空或修改系统已有自定义链。

Nginx 逻辑：

- 使用独立配置 `/etc/nginx/feilian-tcp-transparent-proxy.conf`。
- 使用独立 systemd 服务运行，不直接修改系统默认 `/etc/nginx/nginx.conf`。
- 通过 stream 模块转发 TCP 流量。

持久化说明：

- Nginx stream 服务会开机启动。
- iptables 恢复服务会开机执行。
- 重启后透明代理规则不会丢失。

#### 12.4.3 删除透明代理配置

删除范围：

- 删除指定目标 IP 的全部透明代理规则。
- 删除指定目标 IP 下的指定目标端口映射。
- 删除全部 TCP 透明代理配置。

删除指定端口时只需要输入目标端口，不需要输入本地端口。脚本会根据规则文件找到对应本地端口并删除。

当所有规则都删除后，脚本会清理：

- 规则文件。
- Nginx stream 配置。
- 独立 Nginx systemd 服务。
- iptables 持久化脚本和服务。
- `FEILIAN_T_PROXY` 专用链。

删除也是固化的，重启后不会恢复已删除规则。

## 13. 输出报告说明

### 13.1 默认终端输出

默认情况下，脚本只在终端实时输出，不自动生成文件。

### 13.2 保存文本报告

使用 `-o` 保存文本报告：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe -f -o /tmp/report.txt
```

保存的文本报告会去除颜色控制字符，便于复制到工单或文档。

### 13.3 保存 JSON 报告

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe -j -o /tmp/report.json
```

JSON 适合自动化系统读取。

## 14. 退出码说明

| 退出码 | 含义 |
|---|---|
| `0` | 所有检查通过。 |
| `1` | 存在失败项。 |
| `2` | 存在警告项。 |
| `127` | 参数错误或脚本执行错误。 |

## 15. 新手常见问题

### 15.1 为什么要 sudo 执行？

因为脚本需要读取服务状态、系统路由、iptables、CPE 配置和日志。普通用户可能没有权限。

### 15.2 直接回车为什么没有退出？

脚本设计为“回车保持当前菜单或确认项”，避免误操作。

### 15.3 确认时输入 YES 可以吗？

不可以。当前确认规则是输入 `y` 或 `Y` 才执行。输入 `YES` 会被当作其他内容并取消。

### 15.4 IP 后面有空格会失败吗？

不会。脚本会自动去掉 IP 前后的空格和换行。

### 15.5 TCP 透明代理会影响已有 iptables 规则吗？

脚本只维护专用链 `FEILIAN_T_PROXY`，不会清空系统已有链。它只会在 `PREROUTING` 中添加到专用链的跳转规则。

### 15.6 TCP 透明代理为什么要用 Nginx？

iptables `REDIRECT` 只负责把流量转到本机端口，Nginx stream 负责把 TCP 连接代理到真实目标 IP 和端口。

### 15.7 本地端口为什么从 20000 开始？

为了避免和常见服务端口冲突。脚本会检查已有规则和系统监听端口，如果 `20000` 被占用，会自动尝试 `20001`、`20002` 等后续端口。

### 15.8 删除 TCP 透明代理后重启还会恢复吗？

不会。删除会同步清理规则文件、Nginx 配置、systemd 服务和专用 iptables 链。

### 15.9 域名调度中 forwarded DNS 是什么？

`forwarded www.example.com to 192.0.2.53` 表示 dnsmasq 实际把域名请求转发给了 `192.0.2.53`。脚本会把它和 `gfw_domain.conf` 中配置的 DNS 对比。

### 15.10 traceroute 第二跳为什么重要？

第二跳通常代表流量进入隧道后的下车 CPE 隧道 IP。它可以帮助确认数据面是否真的按调度规则转发。

## 16. 建议排障流程

### 16.1 设备整体异常

建议顺序：

1. 执行 CPE 全面巡检。
2. 先看失败项。
3. 再看警告项。
4. 查看 CPE ERROR 日志和 Panic 日志。
5. 检查 WireGuard 隧道状态和质量。

命令：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode cpe -f -o /tmp/cpe-full-report.txt
```

### 16.2 IP 调度不生效

建议顺序：

1. 执行 IP 调度排查。
2. 查看路由是否进入隧道。
3. 查看 dispatch 是否命中 IP 调度。
4. 查看调度优先级是否符合预期。
5. 查看 traceroute 第二跳是否为下车 CPE。

命令：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode ip --target-ip 203.0.113.10
```

### 16.3 域名调度不生效

建议顺序：

1. 执行域名调度排查。
2. 查看 `gfw_domain.conf` 是否命中。
3. 查看 `feilian-dnsmasq` 是否正常。
4. 查看 DNS 解析是否成功。
5. 查看 `dnsmasq.query.log*` 中 forwarded DNS 是否正确。
6. 查看解析 IP 是否命中域名调度。
7. 查看 traceroute 第二跳是否符合预期。

命令：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh --mode domain --domain www.aliyun.com
```

## 17. 安全注意事项

- 不要在不清楚影响的情况下执行优化脚本。
- 执行优化脚本前建议保留当前巡检报告。
- 修改 POP、路由、iptables、Nginx 可能造成短暂业务中断。
- TCP 透明代理只适合明确目标 IP 和 TCP 端口的场景。
- 不建议把设备敏感日志、认证凭据和认证返回输出上传到公开工单或公开仓库。

## 18. 仓库文件说明

当前建议关注这些文件：

```text
README.md                                      使用说明文档
scripts/feilian-cpe-health-check-pro.sh        主脚本
.gitignore                                     Git 忽略规则
```

