#!/bin/bash

# ==================== 0. 防重入锁 ====================
# flock 保证同一时刻只有一个实例在跑，后到的直接退出
LOCK_FILE="/tmp/disk_check.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "已有巡检实例在运行，本次跳过"; exit 1; }

# ==================== 1. 基础配置与依赖检查 ====================
RECIPIENT="alan_dai@qq.com"
SUBJECT="【$(hostname) 磁盘健康巡检日报】 $(date +'%Y-%m-%d %H:%M')"
REPORT_FILE="/tmp/disk_report.txt"

# --- 自动检查并补齐依赖项 ---
REQUIRED_PACKAGES=""
command -v smartctl &>/dev/null || REQUIRED_PACKAGES="${REQUIRED_PACKAGES} smartmontools"
command -v lsblk &>/dev/null    || REQUIRED_PACKAGES="${REQUIRED_PACKAGES} util-linux"
command -v iostat &>/dev/null   || REQUIRED_PACKAGES="${REQUIRED_PACKAGES} sysstat"
command -v mail &>/dev/null     || REQUIRED_PACKAGES="${REQUIRED_PACKAGES} bsd-mailx"

if [ -n "$REQUIRED_PACKAGES" ]; then
    echo "检测到全新环境缺失依赖项:${REQUIRED_PACKAGES}，正在自动安装..."
    export DEBIAN_FRONTEND=noninteractive
    if ! ( apt-get update -qq && apt-get install -y -qq $REQUIRED_PACKAGES ); then
        echo "ERROR: 依赖安装失败，请手动执行: apt-get install $REQUIRED_PACKAGES" >&2
        exit 1
    fi
    for cmd in smartctl lsblk iostat mail; do
        command -v $cmd &>/dev/null || { echo "ERROR: $cmd 安装后仍不可用" >&2; exit 1; }
    done
fi

# 清空并初始化报告文件
echo "============== PVE 磁盘健康报告 ==============" > "$REPORT_FILE"
echo "生成时间: $(date +'%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
echo "主机名: $(hostname)" >> "$REPORT_FILE"
echo "==============================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ==================== 2. NVMe 盘采集 (/dev/nvme0n1) ====================
NVME_DEV="/dev/nvme0n1"
if [ -b "$NVME_DEV" ]; then
    NVME_MODEL=$(lsblk -d -n -o MODEL $NVME_DEV 2>/dev/null | xargs)
    NVME_CAP=$(lsblk -d -n -o SIZE $NVME_DEV 2>/dev/null | xargs)
    NVME_SMART=$(smartctl -x $NVME_DEV 2>/dev/null)

    [ -z "$NVME_MODEL" ] && NVME_MODEL=$(echo "$NVME_SMART" | grep -i "Model Number:" | awk -F':' '{print $2}' | xargs)
    [ -z "$NVME_MODEL" ] && NVME_MODEL="NVMe SSD"

    # 寿命获取（${VAR:-0} 兜底，SMART 抓取失败时按 0 处理，避免算术空值报错）
    NVME_USED=$(echo "$NVME_SMART" | grep -i "Percentage Used:" | awk -F':' '{print $2}' | tr -d ' %' | grep -oE '[0-9]+' | head -n1)
    NVME_LIFE="$((100 - ${NVME_USED:-0}))%"

    # 读写总量提取（smartctl 自带 [xx TB] 单位，直接取方括号内容）
    NVME_READ_TB=$(echo "$NVME_SMART" | grep -i "Data Units Read:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)
    NVME_WRITE_TB=$(echo "$NVME_SMART" | grep -i "Data Units Written:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)

    NVME_TEMP=$(echo "$NVME_SMART" | grep -i "Temperature:" | head -n 1 | awk '{print $2}' | tr -d ' C°')
    NVME_POWER_ON=$(echo "$NVME_SMART" | grep -i "Power Cycles:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)
    NVME_UNSAFE_OFF=$(echo "$NVME_SMART" | grep -i "Unsafe Shutdowns:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)
    NVME_HOURS=$(echo "$NVME_SMART" | grep -i "Power On Hours:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)

    # 写入报告
    echo "【NVMe 盘】 [nvme0n1] ${NVME_MODEL}" >> "$REPORT_FILE"
    echo "  - 容量: ${NVME_CAP:-N/A} | 寿命: ${NVME_LIFE} (已读: ${NVME_READ_TB:-N/A}, 已写: ${NVME_WRITE_TB:-N/A}) | 温度: ${NVME_TEMP:-N/A}°C" >> "$REPORT_FILE"
    echo "  - 状态: 通电 ${NVME_POWER_ON:-N/A} 次 | 不安全断电 ${NVME_UNSAFE_OFF:-N/A} 次 | 累计运行 ${NVME_HOURS:-N/A} 小时" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# ==================== 3. SATA 盘采集 (/dev/sda) ====================
SATA_DEV="/dev/sda"
if [ -b "$SATA_DEV" ]; then
    SATA_MODEL=$(lsblk -d -n -o MODEL $SATA_DEV 2>/dev/null | xargs)
    SATA_SMART=$(smartctl -x $SATA_DEV 2>/dev/null)

    # 容量与通电时间
    SATA_CAP=$(lsblk -d -n -o SIZE $SATA_DEV 2>/dev/null | xargs)
    [ -z "$SATA_CAP" ] && SATA_CAP=$(echo "$SATA_SMART" | grep -i "User Capacity:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)

    SATA_HOURS=$(echo "$SATA_SMART" | grep -iE "Power_On_Hours|Power-on Hours" | grep -oE '[0-9]+' | tail -n1)

    # 通电次数与不安全断电（174 优先，192 兜底；850 EVO 固件无此两字段时输出 N/A）
    SATA_POWER_CYCLE=$(echo "$SATA_SMART" | grep -E "\b12 Power_Cycle_Count\b" | awk '{print $NF}')
    SATA_UNSAFE=$(echo "$SATA_SMART" | grep -E "\b174 Unexpect_Power_Loss_Ct\b" | awk '{print $NF}')
    [ -z "$SATA_UNSAFE" ] && SATA_UNSAFE=$(echo "$SATA_SMART" | grep -E "\b192 Power-Off_Retract_Count\b" | awk '{print $NF}')

    # 温度
    SATA_TEMP=$(echo "$SATA_SMART" | grep -i "Current Temperature:" | head -n1 | awk '{print $3}')
    [ -z "$SATA_TEMP" ] && SATA_TEMP=$(echo "$SATA_SMART" | grep -E "194 Temperature_Celsius|190 Airflow_Temperature" | awk '{print $NF}' | head -n1)

    # 寿命多重提取：
    #   Micron 5100 → devstat 表格行 "Percentage Used Endurance Indicator"（值在第 4 列，行内无冒号，实测已用 1%）
    #   部分固件    → 202 Percentage_Used（RAW=已用百分比，如 1 → 99%）
    #   三星 850 EVO → 177 Wear_Leveling_Count 的 VALUE 列（第 4 列，剩余寿命百分比）
    SATA_USED=$(echo "$SATA_SMART" | grep -i "Percentage Used Endurance Indicator" | awk '{print $4}' | grep -oE '[0-9]+' | head -n1)
    [ -z "$SATA_USED" ] && SATA_USED=$(echo "$SATA_SMART" | grep -E "\b202 Percentage_Used\b" | awk '{print $NF}' | grep -oE '[0-9]+' | head -n1)
    if [ -n "$SATA_USED" ]; then
        SATA_LIFE="$((100 - ${SATA_USED:-0}))%"
    else
        SATA_WEAR=$(echo "$SATA_SMART" | grep -E "\b177 Wear_Leveling_Count\b" | awk '{print $4}' | sed 's/^0*//')
        if [ -n "$SATA_WEAR" ] && [ "$SATA_WEAR" -ge 0 ] 2>/dev/null; then
            SATA_LIFE="${SATA_WEAR}%"
        else
            SATA_LIFE="未知"
        fi
    fi

    # 读写总量提取：
    #   devstat 值带千分位逗号（如 6,338,402,530,321），必须整体提取再去逗号，否则 tail 只取到尾段三位数
    #   兜底链：devstat → 241/242 标准属性 → 246（Micron 5100 专属，无标准 241）
    WRITE_SECTORS=$(echo "$SATA_SMART" | grep -i "Logical Sectors Written" | grep -oE '[0-9,]+' | tail -n1 | tr -d ',')
    [ -z "$WRITE_SECTORS" ] && WRITE_SECTORS=$(echo "$SATA_SMART" | grep -E "\b241 Total_LBAs_Written\b" | awk '{print $NF}' | grep -oE '[0-9]+')
    [ -z "$WRITE_SECTORS" ] && WRITE_SECTORS=$(echo "$SATA_SMART" | grep -E "\b246 Total_LBAs_Written\b" | awk '{print $NF}' | grep -oE '[0-9]+')

    READ_SECTORS=$(echo "$SATA_SMART" | grep -i "Logical Sectors Read" | grep -oE '[0-9,]+' | tail -n1 | tr -d ',')
    [ -z "$READ_SECTORS" ] && READ_SECTORS=$(echo "$SATA_SMART" | grep -E "\b242 Total_LBAs_Read\b" | awk '{print $NF}' | grep -oE '[0-9]+')

    # 格式化读写统计（扇区数 × 512B 换算 TB）
    IO_STAT_STR=""
    if [ -n "$READ_SECTORS" ]; then
        SATA_READ_TB=$(awk "BEGIN {printf \"%.1f\", $READ_SECTORS * 512 / 1000000000000}")
        IO_STAT_STR="已读: ${SATA_READ_TB} TB, "
    fi

    if [ -n "$WRITE_SECTORS" ]; then
        SATA_WRITE_TB=$(awk "BEGIN {printf \"%.1f\", $WRITE_SECTORS * 512 / 1000000000000}")
        IO_STAT_STR="${IO_STAT_STR}已写: ${SATA_WRITE_TB} TB"
    else
        IO_STAT_STR="${IO_STAT_STR}已写: 未知"
    fi

    # 写入报告
    echo "【SATA 盘】 [sda] ${SATA_MODEL:-SATA SSD}" >> "$REPORT_FILE"
    echo "  - 容量: ${SATA_CAP:-N/A} | 寿命: ${SATA_LIFE} (${IO_STAT_STR})" >> "$REPORT_FILE"
    echo "  - 状态: 通电 ${SATA_POWER_CYCLE:-N/A} 次 | 不安全断电 ${SATA_UNSAFE:-N/A} 次 | 累计通电 ${SATA_HOURS:-N/A} 小时 | 温度: ${SATA_TEMP:-N/A}°C" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# ==================== 4. 实时 I/O 简报 ====================
# 注：不加 -y（老版本 sysstat 不支持），输出两轮，第二段为瞬时采样值
if command -v iostat &> /dev/null; then
    echo "---------------- [实时 I/O 性能评估] ----------------" >> "$REPORT_FILE"
    iostat -x -d 1 2 >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# ==================== 5. 发送邮件与清理 ====================
mail -s "$SUBJECT" "$RECIPIENT" < "$REPORT_FILE"
rm -f "$REPORT_FILE"
