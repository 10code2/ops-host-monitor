#!/bin/bash
# ============================================================
# config_backup.sh —— 配置文件自动备份脚本
# 功能：备份 nginx 配置和重要目录，压缩归档，保留历史版本
# 用法：bash config_backup.sh
# ============================================================

# 【生产规范】crontab 环境必须显式声明 PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==================== 配置区 ====================
BACKUP_DIR="/var/backups/ops-monitor"   # 备份文件存放目录
KEEP_BACKUPS=7                            # 保留最近 N 个备份（轮转删除）
LOG_FILE="/var/log/config_backup.log"     # 备份操作日志

# 要备份的目录/文件列表（不存在的自动跳过，不报错）
BACKUP_SOURCES=(
    "/etc/nginx"
    "/etc/nginx/sites-available/mysite"
    "/var/www/mysite"
)

# ==================== 函数 ====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ==================== 主流程 ====================
log "===== 配置备份开始 ====="

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 生成带时间戳的备份文件名（精确到秒，避免覆盖）
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="$BACKUP_DIR/config_backup_${TIMESTAMP}.tar.gz"

# 过滤掉不存在的路径（避免 tar 报错中断）
VALID_SOURCES=()
for src in "${BACKUP_SOURCES[@]}"; do
    if [ -e "$src" ]; then
        VALID_SOURCES+=("$src")
    else
        log "⚠️  路径不存在，跳过：$src"
    fi
done

if [ ${#VALID_SOURCES[@]} -eq 0 ]; then
    log "❌ 没有可备份的有效路径"
    exit 1
fi

# 执行压缩备份（-P 保留绝对路径，-z gzip 压缩）
tar -czf "$BACKUP_FILE" "${VALID_SOURCES[@]}" 2>>"$LOG_FILE"

if [ $? -eq 0 ]; then
    SIZE=$(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1)
    log "✅ 备份成功：$BACKUP_FILE（$SIZE）"
else
    log "❌ 备份失败，检查 $LOG_FILE"
    exit 1
fi

# 轮转删除：只保留最近 KEEP_BACKUPS 个备份
cd "$BACKUP_DIR" || exit 1
ls -t config_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
    rm -f "$old"
    log "🗑️  删除旧备份：$old"
done

current_count=$(ls config_backup_*.tar.gz 2>/dev/null | wc -l)
log "📊 当前备份数量：$current_count / $KEEP_BACKUPS"
log "===== 配置备份完成 ====="
exit 0
