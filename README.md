# Feilian CPE 健康巡检工具

本仓库用于维护飞连 SD-WAN CPE 健康巡检、IP 调度排查、域名调度排查和常见优化脚本。

## 脚本位置

- `scripts/feilian-cpe-health-check-pro.sh`

## 主要能力

- CPE 全面健康巡检：系统基础信息、关键服务、日志、网络连通性、POP/WireGuard 隧道状态等。
- CPE IP 发布检查：IP 调度规则、路由、NAT、traceroute 数据面转发验证等。
- CPE 域名调度检查：dnsmasq 规则匹配、解析日志、forwarded DNS 一致性、域名解析 IP 调度和 traceroute 验证。
- WireGuard 隧道质量检测：基于 `feilian-tun-ctrl measure` 输出分析 RTT、抖动、丢包、流量和质量评级。
- 常见优化脚本：POP 重选、固定 POP、默认路由入口策略、TCP 透明代理配置管理。

## 使用方法

```bash
chmod +x scripts/feilian-cpe-health-check-pro.sh
sudo ./scripts/feilian-cpe-health-check-pro.sh
```

查看帮助：

```bash
./scripts/feilian-cpe-health-check-pro.sh --help
```

保存巡检报告：

```bash
sudo ./scripts/feilian-cpe-health-check-pro.sh -f -o /tmp/feilian-cpe-report.txt
```

## 交互菜单

- `1. CPE巡检`：执行全面健康巡检。
- `2. CPE IP发布检查`：排查指定目标 IP 的调度链路。
- `3. CPE 域名调度检查`：排查指定域名的调度链路。
- `4. CPE常见优化脚本`：提供确认式优化动作入口。

## TCP 透明代理说明

在 `CPE常见优化脚本 -> TCP透明代理` 中可以管理透明代理规则：

- 只需要输入目标 IP 和目标端口，例如 `30.100.1.1`、`23`。
- 本地代理端口自动从 `20000` 开始分配。
- 自动检查已有规则和系统监听端口，避免端口冲突。
- 使用脚本专用 iptables 链 `FEILIAN_T_PROXY`，避免影响系统已有 iptables 链。
- 使用独立 Nginx stream 配置和 systemd 服务进行持久化，重启后规则不丢失。

## 注意事项

- 建议使用 `root` 或 `sudo` 执行，否则部分系统状态、iptables、systemd 操作无法完成。
- 脚本会读取 CPE 本机配置和日志，仅用于运维巡检与排障。
- 执行优化类动作前会进行二次确认，输入 `y/Y` 才会执行。
