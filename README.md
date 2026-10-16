# ops-host-monitor

> 单机简易运维监控平台 · 基于 Linux + Shell + crontab
> 环境：WSL2 Debian + nginx 1.26 · 开发周期：2 天

## 项目背景

运维日常需要持续监控服务器状态，手动逐个执行 `df`、`free`、`ss` 效率低且容易遗漏。本项目将初级运维的日常巡检工作自动化：定时采集主机指标，超过阈值触发告警，同时配套日志清理和配置备份脚本，避免磁盘占满和配置丢失。

## 技术栈

| 类别 | 技术 |
|---|---|
| 操作系统 | Linux（WSL2 Debian） |
| 脚本语言 | Bash Shell |
| 定时任务 | crontab |
| 被监控服务 | Nginx（反向代理 + 负载均衡） |
| 文本处理 | awk / sed / grep |
| 数据采集 | uptime / free / df / ss / pgrep / dmesg |

## 功能清单

### 1. 主机指标巡检（host_monitor.sh）

8 个检查维度，阈值可配置，退出码规范（0=正常 / 1=告警 / 2=严重）：

| 检查项 | 采集命令 | 告警阈值 |
|---|---|---|
| CPU 负载 | `uptime` | 1分钟 load > 2.0 |
| 内存可用率 | `free -m` | 可用率 < 10% |
| 磁盘使用率 | `df -P` | 使用率 > 80% |
| inode 使用率 | `df -iP` | 使用率 > 80% |
| 端口监听 | `ss -tlnp` | 指定端口未监听 → 严重 |
| 关键进程 | `pgrep -x` | 指定进程未运行 → 严重 |
| 内核错误日志 | `dmesg --level=err` | 存在 error 级日志 → 告警 |
| swap 使用率 | `free -m` | 使用率 > 50% |

输出示例：
```
[2026-10-16 22:00:00] [INFO] ✅ CPU负载 — 1分钟load=0.03（阈值2.0）
[2026-10-16 22:00:00] [WARN] ⚠️  内存 — 可用率=8.2% < 阈值10%
[2026-10-16 22:00:00] [ERROR] ❌ 端口9001 — 未监听
[2026-10-16 22:00:00] [INFO] 总检查项: 17 | 通过: 14 | 告警: 1 | 严重: 2
```

### 2. 日志自动清理（log_clean.sh）

- 压缩超过 7 天的 `.log` 文件（gzip）
- 删除超过 30 天的 `.gz` 归档
- 清理操作自身记日志，可追溯

### 3. 配置自动备份（config_backup.sh）

- 备份 `/etc/nginx`、站点配置、网站根目录
- 压缩为带时间戳的 `tar.gz`（精确到秒，不覆盖）
- 自动轮转，只保留最近 7 个备份
- 不存在的路径自动跳过，不中断备份

### 4. crontab 定时执行

| 任务 | 频率 |
|---|---|
| 主机巡检 | 每 30 分钟 |
| 日志清理 | 每天 03:00 |
| 配置备份 | 每天 04:00 |

## 目录结构

```
ops-host-monitor/
├── README.md              # 项目说明 + 踩坑记录
├── host_monitor.sh        # 核心巡检脚本（8 维度）
├── log_clean.sh           # Nginx 日志清理脚本
├── config_backup.sh       # 配置备份脚本
├── crontab_task.txt       # crontab 配置示例
└── report/                # 巡检报告输出目录
```

## 部署步骤（WSL 环境）

```bash
# 1. 克隆项目到 /opt
sudo git clone <repo-url> /opt/ops-host-monitor
cd /opt/ops-host-monitor

# 2. 转换换行符（Windows 编辑的脚本是 CRLF，Linux 需要 LF）
sed -i 's/\r$//' *.sh

# 3. 加执行权限
chmod +x *.sh

# 4. 修改配置区（阈值、检查名单、备份路径）
vim host_monitor.sh    # 顶部配置区
vim log_clean.sh       # 日志目录、保留天数
vim config_backup.sh   # 备份源、保留数量

# 5. 手动测试
./host_monitor.sh
./log_clean.sh
./config_backup.sh

# 6. 安装定时任务
(crontab -l 2>/dev/null; cat crontab_task.txt) | crontab -

# 7. 验证定时任务
crontab -l
service cron status
```

## 踩坑记录（面试加分项）

### 坑 1：crontab 环境变量导致脚本定时执行失败

**现象**：脚本手动执行完全正常，但 crontab 定时执行时报 `command not found`。

**根因**：crontab 执行脚本时的环境变量和交互式 shell 不一样。交互式 shell 的 PATH 包含 `/usr/local/bin` 等路径，而 crontab 的 PATH 只有 `/usr/bin:/bin`。脚本里如果调用了不在标准路径下的命令（如 `/usr/local/bin` 下的自定义命令），就会失败。

**修复**：在每个脚本头部显式声明完整 PATH：
```bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**面试话术**："最开始遇到 crontab 环境变量问题，脚本手动跑没问题，定时执行失败。排查后发现 crontab 的 PATH 环境变量不全，在脚本头部手动指定 PATH 解决。这让我意识到定时任务的运行环境和交互式 shell 是隔离的，生产脚本必须自包含环境变量。"

### 坑 2：df 全量扫描误报 tmpfs 虚拟磁盘

**现象**：用 `df -h` 全量扫描磁盘时，`tmpfs`、`devtmpfs` 等虚拟文件系统也被统计，使用率经常 100%，误触发告警。

**根因**：`df` 默认列出所有挂载点，包括内存文件系统（tmpfs），这些不是真实磁盘。

**修复**：不做全量扫描，改用 `CHECK_DISKS` 数组指定需要监控的真实挂载点（如 `/`、`/data`），逐个检查。这样既过滤了虚拟磁盘，又避免了新增挂载点后意外告警。

### 坑 3：WSL 环境下 systemctl 不可用

**现象**：按照教程用 `systemctl status nginx` 检查服务状态，命令直接卡死无响应。

**根因**：WSL2 的 init 进程不是 systemd（pid1=init），不支持 systemctl。

**修复**：改用 `service nginx status` 管理服务，或用 `pgrep -x nginx` 检测进程。进程检测比 systemd 服务检测更通用——容器环境、极简镜像、WSL 都没有 systemd，但 `pgrep` 一定可用。

### 坑 4：Windows / Linux 换行符不兼容

**现象**：在 Windows 上编辑的脚本传到 Linux 执行，报 `$'\r': command not found` 和 `unexpected end of file`。

**根因**：Windows 换行是 CRLF（`\r\n`），Linux 是 LF（`\n`）。每行末尾多的 `\r` 被 shell 当成命令名。

**修复**：`sed -i 's/\r$//' script.sh` 批量转换，或在编辑器中设置 LF 换行。

### 坑 5：awk 正则大小写敏感导致取空值

**现象**：`free -m | awk '/^MEM:/{print $2}'` 取到空值，后续计算出现 `nan`。

**根因**：`free` 输出的行首是 `Mem:`（首字母大写其余小写），awk 正则 `/^MEM:/` 全大写匹配不到。

**修复**：严格按照命令实际输出写正则，或用 `awk 'tolower($1)=="mem:"'` 忽略大小写。

## 项目不足与扩展方向

**当前不足**（面试主动说，显得真实）：
- 仅单机监控，无多节点聚合
- 无 Web 可视化界面，输出为文本日志
- 告警方式仅文本记录，未接入邮件/钉钉/企业微信

**后续可扩展**：
- 接入邮件告警（`mailx` + SMTP）
- 加 Web 仪表盘（Python Flask + ECharts）
- 多节点采集（SSH 批量执行 + 中心汇总）
- 接入 Prometheus + Grafana（生产级监控栈）

## 许可证

MIT
