#!/bin/bash
# ============================================================
# log_clean.sh —— Nginx 日志自动清理脚本
# 功能：压缩超过保留天数的日志，删除超期归档，避免磁盘占满
# 用法：bash log_clean.sh
# ============================================================

# 【生产规范】crontab 环境的 PATH 只有 /usr/bin:/bin，必须显式声明
# 踩坑：不写 PATH，手动执行正常，crontab 定时执行报 command not found
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==================== 配置区 ====================
LOG_DIR="/var/log/nginx"            # 待清理的日志目录
KEEP_DAYS=7                          # 普通 .log 保留天数（超过则压缩）
ARCHIVE_KEEP_DAYS=30                 # .gz 归档保留天数（超过则删除）
LOG_FILE="/var/log/log_clean.log"    # 清理操作自身的日志

# ==================== 函数 ====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ==================== 主流程 ====================
log "===== 日志清理开始 ====="

# 安全检查：日志目录必须存在
if [ ! -d "$LOG_DIR" ]; then
    log "❌ 日志目录不存在：$LOG_DIR"
    exit 1
fi

# 1. 压缩超过 KEEP_DAYS 天的 .log 文件
count=$(find "$LOG_DIR" -maxdepth 1 -name "*.log" -type f -mtime +$KEEP_DAYS 2>/dev/null | wc -l)
if [ "$count" -gt 0 ]; then
    find "$LOG_DIR" -maxdepth 1 -name "*.log" -type f -mtime +$KEEP_DAYS -exec gzip {} \;
    log "✅ 已压缩 $count 个超过 ${KEEP_DAYS} 天的日志文件"
else
    log "ℹ️  没有超过 ${KEEP_DAYS} 天的日志需要压缩"
fi

# 2. 删除超过 ARCHIVE_KEEP_DAYS 天的 .gz 归档
gz_count=$(find "$LOG_DIR" -maxdepth 1 -name "*.gz" -type f -mtime +$ARCHIVE_KEEP_DAYS 2>/dev/null | wc -l)
if [ "$gz_count" -gt 0 ]; then
    find "$LOG_DIR" -maxdepth 1 -name "*.gz" -type f -mtime +$ARCHIVE_KEEP_DAYS -delete
    log "🗑️  已删除 $gz_count 个超过 ${ARCHIVE_KEEP_DAYS} 天的归档文件"
else
    log "ℹ️  没有超过 ${ARCHIVE_KEEP_DAYS} 天的归档需要删除"
fi

# 3. 输出当前日志目录占用
usage=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
log "📊 当前日志目录占用：$usage"

log "===== 日志清理完成 ====="
exit 0
