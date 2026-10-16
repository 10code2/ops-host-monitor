#!/bin/bash
# ============================================================
# host_monitor.sh —— 单机主机巡检脚本
# 功能：采集 CPU/内存/磁盘/inode/端口/进程/内核日志/swap，阈值告警
# 用法：bash host_monitor.sh
# 退出码：0=全部正常  1=有告警  2=有严重错误
# ============================================================

# 【生产规范】crontab 环境必须显式声明 PATH
# 踩坑记录：不写 PATH，手动执行正常，crontab 定时执行报 command not found
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==================== 配置区（运维只改这里） ====================
CPU_LOAD_WARN=2.0          # 1分钟 load 告警阈值（一般设为 CPU 核数）
MEM_FREE_WARN=10           # 内存可用率低于多少 % 告警
DISK_USE_WARN=80           # 磁盘使用率高于多少 % 告警
INODE_USE_WARN=80          # inode 使用率高于多少 % 告警
SWAP_USE_WARN=50           # swap 使用率高于多少 % 告警

CHECK_PORTS=(8080 8443 9000 9001 9002)   # 必须监听的端口
CHECK_PROCS=(nginx python3)              # 必须运行的进程
CHECK_DISKS=(/ /mnt/c /mnt/d)            # 必须检查的挂载点

LOG_FILE="/var/log/host_monitor.log"     # 巡检日志

# ==================== 全局状态 ====================
PASS_COUNT=0
WARN_COUNT=0
ERROR_COUNT=0

# ==================== 底层：日志 ====================
log() {
    local level=$1 msg=$2 ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg"
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null
}

# 统一记录检查结果（所有 check_* 都调它）
record() {
    local status=$1 item=$2 detail=$3
    case $status in
        PASS)  PASS_COUNT=$((PASS_COUNT+1));  log "INFO"  "✅ $item — $detail" ;;
        WARN)  WARN_COUNT=$((WARN_COUNT+1));  log "WARN"  "⚠️  $item — $detail" ;;
        ERROR) ERROR_COUNT=$((ERROR_COUNT+1)); log "ERROR" "❌ $item — $detail" ;;
    esac
}

# ==================== 检查函数 ====================

# 1. CPU 负载
check_cpu() {
    local load over
    load=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    over=$(awk -v l="$load" -v t="$CPU_LOAD_WARN" 'BEGIN{print (l>t)?1:0}')
    if [ "$over" = "1" ]; then
        record "WARN" "CPU负载" "1分钟load=$load > 阈值$CPU_LOAD_WARN"
    else
        record "PASS" "CPU负载" "1分钟load=$load（阈值$CPU_LOAD_WARN）"
    fi
}

# 2. 内存（awk 匹配 /^Mem:/ 大小写敏感！）
check_mem() {
    local total available free_pct low
    total=$(free -m | awk '/^Mem:/{print $2}')
    available=$(free -m | awk '/^Mem:/{print $7}')
    free_pct=$(awk -v a="$available" -v t="$total" 'BEGIN{printf "%.1f", a/t*100}')
    low=$(awk -v f="$free_pct" -v t="$MEM_FREE_WARN" 'BEGIN{print (f<t)?1:0}')
    if [ "$low" = "1" ]; then
        record "WARN" "内存" "可用率=${free_pct}% < 阈值${MEM_FREE_WARN}%（${available}M/${total}M）"
    else
        record "PASS" "内存" "可用率=${free_pct}%（${available}M/${total}M）"
    fi
}

# 3. 磁盘使用率（指定挂载点，天然过滤 tmpfs）
check_disk() {
    for mp in "${CHECK_DISKS[@]}"; do
        local use
        use=$(df -P "$mp" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
        if [ -z "$use" ]; then
            record "ERROR" "磁盘$mp" "挂载点不存在或无法读取"
            continue
        fi
        if [ "$use" -ge "$DISK_USE_WARN" ]; then
            record "WARN" "磁盘$mp" "使用率=${use}% >= 阈值${DISK_USE_WARN}%"
        else
            record "PASS" "磁盘$mp" "使用率=${use}%"
        fi
    done
}

# 4. inode（含健壮性：WSL 的 DrvFs 不支持 inode，显示 "-"）
check_inode() {
    for mp in "${CHECK_DISKS[@]}"; do
        local use
        use=$(df -iP "$mp" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
        if [[ ! "$use" =~ ^[0-9]+$ ]]; then
            record "PASS" "Inode$mp" "不支持 inode 统计（跳过）"
            continue
        fi
        if [ "$use" -ge "$INODE_USE_WARN" ]; then
            record "WARN" "Inode$mp" "使用率=${use}% >= 阈值${INODE_USE_WARN}%"
        else
            record "PASS" "Inode$mp" "使用率=${use}%"
        fi
    done
}

# 5. 端口监听
check_ports() {
    for port in "${CHECK_PORTS[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            record "PASS" "端口$port" "监听中"
        else
            record "ERROR" "端口$port" "未监听"
        fi
    done
}

# 6. 关键进程（用 pgrep -x，不会匹配到 grep 自己）
check_procs() {
    for proc in "${CHECK_PROCS[@]}"; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            record "PASS" "进程$proc" "运行中"
        else
            record "ERROR" "进程$proc" "未运行"
        fi
    done
}

# 7. 内核错误日志
check_dmesg() {
    local err_count
    err_count=$(dmesg --level=err,crit,alert,emerg 2>/dev/null | wc -l)
    if [ "$err_count" -gt 0 ]; then
        record "WARN" "内核日志" "存在 ${err_count} 条 error/crit 级日志"
    else
        record "PASS" "内核日志" "无 error 级日志"
    fi
}

# 8. swap（虚拟内存）
check_swap() {
    local total used used_pct over
    total=$(free -m | awk '/^Swap:/{print $2}')
    used=$(free -m | awk '/^Swap:/{print $3}')
    [ "$total" = "0" ] || [ -z "$total" ] && { record "PASS" "虚拟内存" "未启用 swap"; return; }
    used_pct=$(awk -v a="$used" -v t="$total" 'BEGIN{printf "%.1f", a/t*100}')
    over=$(awk -v u="$used_pct" -v t="$SWAP_USE_WARN" 'BEGIN{print (u>t)?1:0}')
    if [ "$over" = "1" ]; then
        record "WARN" "虚拟内存" "使用率=${used_pct}% > 阈值${SWAP_USE_WARN}%（${used}M/${total}M）"
    else
        record "PASS" "虚拟内存" "使用率=${used_pct}%（${used}M/${total}M）"
    fi
}

# ==================== 主流程 ====================
main() {
    log "INFO" "===== 巡检开始 ====="
    check_cpu
    check_mem
    check_disk
    check_inode
    check_ports
    check_procs
    check_dmesg
    check_swap

    local total=$((PASS_COUNT + WARN_COUNT + ERROR_COUNT))
    echo ""
    log "INFO" "===== 巡检汇总 ====="
    log "INFO" "总检查项: $total | 通过: $PASS_COUNT | 告警: $WARN_COUNT | 严重: $ERROR_COUNT"

    if [ "$ERROR_COUNT" -gt 0 ]; then
        log "ERROR" "巡检结果: 存在严重错误"
        exit 2
    elif [ "$WARN_COUNT" -gt 0 ]; then
        log "WARN" "巡检结果: 存在告警"
        exit 1
    else
        log "INFO" "巡检结果: 全部正常"
        exit 0
    fi
}

main "$@"
