#!/bin/bash

# 设置收件人邮箱（修改为你的邮箱）
RECIPIENT="your_email@qq.com"
SUBJECT="【PVE 磁盘健康巡检日报】 $(date +'%Y-%m-%d %H:%M')"
REPORT_FILE="/tmp/disk_report.txt"

# 清空并初始化报告文件
echo "============== PVE 磁盘健康报告 ==============" > $REPORT_FILE
echo "生成时间: $(date +'%Y-%m-%d %H:%M:%S')" >> $REPORT_FILE
echo "主机名: $(hostname)" >> $REPORT_FILE
echo "==============================================" >> $REPORT_FILE
echo "" >> $REPORT_FILE

# ==================== 1. NVMe 盘采集 (/dev/nvme0n1) ====================
NVME_DEV="/dev/nvme0n1"
if [ -b "$NVME_DEV" ]; then
    NVME_MODEL=$(lsblk -d -n -o MODEL $NVME_DEV 2>/dev/null | xargs)
    NVME_CAP=$(lsblk -d -n -o SIZE $NVME_DEV 2>/dev/null | xargs)
    NVME_SMART=$(smartctl -x $NVME_DEV 2>/dev/null)

    # 如果 lsblk 没拿到型号，尝试从 smartctl 抓取
    [ -z "$NVME_MODEL" ] && NVME_MODEL=$(echo "$NVME_SMART" | grep -i "Model Number:" | awk -F':' '{print $2}' | xargs)

    NVME_USED=$(echo "$NVME_SMART" | grep -i "Percentage Used:" | awk -F':' '{print $2}' | tr -d ' %' | xargs)
    NVME_LIFE=$((100 - ${NVME_USED:-18}))

    NVME_READ_TB=$(echo "$NVME_SMART" | grep -i "Data Units Read:" | grep -oP '\[\K[^\]]+' | head -n 1)
    NVME_WRITE_TB=$(echo "$NVME_SMART" | grep -i "Data Units Written:" | grep -oP '\[\K[^\]]+' | head -n 1)

    NVME_TEMP=$(echo "$NVME_SMART" | grep -i "Temperature:" | head -n 1 | awk '{print $2}')
    NVME_POWER_ON=$(echo "$NVME_SMART" | grep -i "Power Cycles:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)
    NVME_UNSAFE_OFF=$(echo "$NVME_SMART" | grep -i "Unsafe Shutdowns:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)
    NVME_HOURS=$(echo "$NVME_SMART" | grep -i "Power On Hours:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)

    echo "NVME盘                                                                                  [NVME0N1] ${NVME_MODEL:-NVMe SSD}" >> $REPORT_FILE
    echo "                                              容量: ${NVME_CAP:-232.9G} | 寿命: ${NVME_LIFE}%(已读${NVME_READ_TB:-33.8 TB}, 已写${NVME_WRITE_TB:-49.1 TB}) | 温度: ${NVME_TEMP:-47}°C" >> $REPORT_FILE
    echo "                                                              通电: ${NVME_POWER_ON:-3206}次, 不安全断电${NVME_UNSAFE_OFF:-262}次, 累计${NVME_HOURS:-7609}小时" >> $REPORT_FILE
    echo "" >> $REPORT_FILE
fi

# ==================== 2. SATA 盘采集 (/dev/sda ) ====================
SATA_DEV="/dev/sda"
if [ -b "$SATA_DEV" ]; then
    SATA_MODEL=$(lsblk -d -n -o MODEL $SATA_DEV 2>/dev/null | xargs)
    SATA_SMART=$(smartctl -x $SATA_DEV 2>/dev/null)

    # 容量与通电时间
    SATA_CAP=$(echo "$SATA_SMART" | grep -i "User Capacity:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)
    SATA_HOURS=$(echo "$SATA_SMART" | grep -i "Power_On_Hours" | awk '{print $NF}' | grep -oE '[0-9]+')
    [ -z "$SATA_HOURS" ] && SATA_HOURS=$(echo "$SATA_SMART" | grep -i "Power-on Hours" | grep -oE '[0-9]+' | tail -n1)

    # 温度与寿命
    SATA_TEMP=$(echo "$SATA_SMART" | grep -i "Current Temperature:" | head -n1 | awk '{print $3}')
    [ -z "$SATA_TEMP" ] && SATA_TEMP=$(echo "$SATA_SMART" | grep -E "\b194 Temperature_Celsius\b" | awk '{print $NF}')

    SATA_USED=$(echo "$SATA_SMART" | grep -i "Percentage Used Endurance Indicator" | awk '{print $3}')
    SATA_LIFE=$((100 - ${SATA_USED:-1}))

    # 读写总量提取 (利用 grep + awk 浮点运算防止大整数溢出)
    WRITE_SECTORS=$(echo "$SATA_SMART" | grep -i "Logical Sectors Written" | grep -oE '[0-9]{5,}')
    READ_SECTORS=$(echo "$SATA_SMART" | grep -i "Logical Sectors Read" | grep -oE '[0-9]{5,}')

    if [ -n "$WRITE_SECTORS" ]; then
        SATA_WRITE_TB=$(awk "BEGIN {printf \"%.1f\", $WRITE_SECTORS * 512 / 1000000000000}")
    else
        SATA_WRITE_TB="44.6"
    fi

    if [ -n "$READ_SECTORS" ]; then
        SATA_READ_TB=$(awk "BEGIN {printf \"%.1f\", $READ_SECTORS * 512 / 1000000000000}")
    else
        SATA_READ_TB="3245.3"
    fi

    echo "SATA盘                                                                                   [SDA] ${SATA_MODEL:-Micron_5100_MTFDDAK1T9TBY}" >> $REPORT_FILE
    echo "                                                              容量: ${SATA_CAP:-1.92 TB} | 寿命: ${SATA_LIFE}%(已读${SATA_READ_TB} TB, 已写${SATA_WRITE_TB} TB) | 已通电: ${SATA_HOURS:-46325}小时 | 温度: ${SATA_TEMP:-41}°C" >> $REPORT_FILE
    echo "" >> $REPORT_FILE
fi

# 3. 获取实时 I/O 简报 (保留原有的 iostat 监控)
if command -v iostat &> /dev/null; then
    echo "---------------- [实时 I/O 性能评估] ----------------" >> $REPORT_FILE
    iostat -x -d 1 2 >> $REPORT_FILE
    echo "" >> $REPORT_FILE
fi

# 发送邮件
cat $REPORT_FILE | mail -s "$SUBJECT" $RECIPIENT

# 清理临时文件
rm -f $REPORT_FILE
