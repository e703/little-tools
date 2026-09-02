# little-tools

用于服务器维护的小脚本聚合。目标环境：Proxmox VE (PVE) 宿主机 + Ubuntu/Debian 系统。

> 所有脚本均为 Bash，未设置可执行位，统一用 `bash xxx.sh` 运行。部分脚本需要 root 权限。

## 脚本清单

| 脚本 | 作用 | 适用场景 |
|------|------|----------|
| `auto-upgrade.sh` | 系统自动更新 | Ubuntu/Debian 服务器 |
| `he-upgrade.sh` | Hermes 一键升级链 | 已安装 Hermes 的服务器 |
| `net_watchdog.sh` | 网络看门狗，自动恢复网关 | PVE 宿主机（软路由 VM） |
| `optimize.sh` | 内存 / Swap 一键优化 | Ubuntu/Debian/CentOS 7+ |
| `disk_report.sh` | 磁盘健康巡检日报（邮件） | PVE 宿主机（NVMe + SATA） |

## 使用说明

### auto-upgrade.sh — 系统自动更新

```
sudo bash auto-upgrade.sh
```

- 执行 `apt update` + `full-upgrade`（`--purge --auto-remove`）+ `autoremove` + `clean`
- 所有输出（stdout/stderr）同步写入 `/var/log/auto-upgrade.log`
- 依赖：`sudo`、`apt`（Debian 系）
- 注意：`full-upgrade` 会卸载不再需要的包并清除配置，建议先在非生产机验证一轮；脚本不处理重启

建议配合 cron 使用，例如每天凌晨：

```
0 3 * * * /usr/bin/env bash /root/little-tools/auto-upgrade.sh
```

### he-upgrade.sh — Hermes 一键升级链

```
bash he-upgrade.sh
```

- 依次执行：`hermes profile list` → `auto-upgrade.sh` → `hermes update` → `hermes doctor --fix` → `hermes profile list`
- 依赖：`hermes` CLI、`auto-upgrade.sh`（需与本脚本同目录并在 PATH 中可找到，否则请改用 `$(dirname "$0")/auto-upgrade.sh`）

### net_watchdog.sh — 网络看门狗（PVE 专用）

```
sudo bash net_watchdog.sh
```

建议放入 root 的 crontab 每 1~5 分钟执行一次，例如：

```
*/3 * * * * /usr/bin/env bash /root/little-tools/net_watchdog.sh
```

工作流程：

1. 先 ping 局域网网关 VM（`GATEWAY_IP`）：
   - 不通且 VM 未运行 → `qm start` 启动
   - 不通但 VM 在运行 → `qm reset` 硬重置（⚠️ 无失败计数保护，瞬时丢包即触发，建议按需修改）
2. 网关正常后再探测外网（`PUBLIC_TARGETS`，双 IP 冗余）：
   - 正常 → 清零失败计数
   - 异常 → 失败计数累加；达到一半阈值重启 PVE 网络 + 软重启网关 VM；达到最大阈值硬重置网关 VM

**使用前必须修改配置区**：

- `GATEWAY_IP`：软路由/网关 VM 的真实局域网 IP
- `GATEWAY_VMID`：网关 VM 在 PVE 中的 VMID
- `PUBLIC_TARGETS`：外网探测 IP（默认阿里 223.5.5.5 / Cloudflare 1.1.1.1）
- `MAX_FAILURES`：连续失败阈值（默认 10）

依赖：`ping`、PVE 的 `qm` 命令（需 root）。日志写入 `/var/log/net_watchdog.log`，失败计数在 `/tmp/net_watchdog_fail_count`。

### optimize.sh — 内存 / Swap 一键优化

```
sudo bash optimize.sh
```

功能：

- 检查磁盘空间与现有 Swap
- 创建 2GB `/swapfile` 并写入 `/etc/fstab` 开机自动挂载
- 追加内核调优参数（swappiness、cache pressure、dirty 阈值、TCP 内存、file-max）到 `/etc/sysctl.conf` 并立即生效
- 追加文件描述符 / 进程数限制（nofile 65535、nproc 65535）到 `/etc/security/limits.conf`

依赖：`dd`、`mkswap`/`swapon`/`swapoff`、`sysctl`。交互式脚本，会询问是否覆盖旧 Swap。

注意事项：

- 重复运行会向 `/etc/sysctl.conf`、`/etc/security/limits.conf` 追加重复条目（sysctl 后者覆盖前者，无实际危害）
- 删除旧 Swap 时用 `sed -i '/swap/d' /etc/fstab` 会移除所有含 "swap" 的行，若机器上有其他 swap 配置请手动核对
- sysctl 改动前会备份为 `/etc/sysctl.conf.bak.<时间戳>`
- 回滚方式脚本结束时会打印（恢复 sysctl 备份 / 编辑 limits.conf / 删除 swapfile）

### disk_report.sh — 磁盘健康巡检日报（PVE / Linux）

```
sudo bash disk_report.sh
```

功能：采集 NVMe（`/dev/nvme0n1`）与 SATA（`/dev/sda`）磁盘的 SMART 数据并生成报告：

- NVMe：型号、容量、寿命（Percentage Used，抓取失败显示"未知"）、读写总量、温度、通电次数、不安全断电、累计通电小时
- SATA：型号、容量、寿命（Endurance Indicator → 202 Percentage_Used → Wear_Leveling_Count 多重兜底）、读写总量（devstat 优先（兼容千分位逗号），241/242 标准属性兜底，246 适配部分 SSD）、通电次数、不安全断电（174 优先，192 兜底）、累计通电小时、温度
- 附送 `iostat -x -d 1 2` 实时 I/O 简报（不加 `-y` 以兼容老版本 sysstat，输出两轮，第二段为瞬时采样值）
- 通过本地 `mail` 命令发送报告
- 自带 flock 防重入锁（`/tmp/disk_report.lock`），cron 重叠执行时后到的实例直接退出
- 自动安装缺失依赖：smartmontools、util-linux、sysstat、bsd-mailx（`DEBIAN_FRONTEND=noninteractive`，仅 apt 系）
- 非 root 直接退出（smartctl 需要 root 权限）

**使用前配置收件人邮箱**（通过环境变量，未配置时脚本拒绝运行）：

```bash
export DISK_CHECK_EMAIL=you@example.com
# 建议写入 /etc/environment 或 cron 定义行持久化
```

cron 示例（每天 08:00，crontab -e）：

```
DISK_CHECK_EMAIL=you@example.com
0 8 * * * /usr/bin/env bash /root/little-tools/disk_report.sh
```

注意：

- 依赖本地 MTA 发送外网邮件，需先配好 postfix/msmtp 等
- 邮件发送失败时报告会保留在 `/tmp/disk_report.txt` 便于排查
- 仅覆盖 `nvme0n1` 和 `sda` 各一块盘，多盘机器需自行扩展
- 部分老固件盘（如三星 850 EVO）不提供累计读/断电计数字段，对应项显示 N/A，属固件限制

## 许可证

MIT（见 LICENSE）
