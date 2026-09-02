#!/bin/bash
# ==================== 0. 基础配置与依赖检查 ====================
# 设置收件人邮箱（修改为你的邮箱）
RECIPIENT="your_email@qq.com"
#邮件主题即可区分主机，避免忘记替换
SUBJECT="【$(hostname) 磁盘健康巡检日报】 $(date +'%Y-%m-%d %H:%M')"
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

    [ -z "$NVME_MODEL" ] && NVME_MODEL=$(echo "$NVME_SMART" | grep -i "Model Number:" | awk -F':' '{print $2}' | xargs)
    [ -z "$NVME_MODEL" ] && NVME_MODEL="NVMe SSD"

    # 寿命获取 (兼容计算与去除前导0)
    NVME_USED=$(echo "$NVME_SMART" | grep -i "Percentage Used:" | awk -F':' '{print $2}' | tr -d ' %' | grep -oE '[0-9]+')
    if [ -n "$NVME_USED" ]; then
        NVME_LIFE="$((100 - NVME_USED))%"
    else
        NVME_LIFE="未知"
    fi

    # 读写总量提取
    NVME_READ_TB=$(echo "$NVME_SMART" | grep -i "Data Units Read:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)
    NVME_WRITE_TB=$(echo "$NVME_SMART" | grep -i "Data Units Written:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)

    NVME_TEMP=$(echo "$NVME_SMART" | grep -i "Temperature:" | head -n 1 | awk '{print $2}' | tr -d ' C°')
    NVME_POWER_ON=$(echo "$NVME_SMART" | grep -i "Power Cycles:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)
    NVME_UNSAFE_OFF=$(echo "$NVME_SMART" | grep -i "Unsafe Shutdowns:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)
    NVME_HOURS=$(echo "$NVME_SMART" | grep -i "Power On Hours:" | awk -F':' '{print $2}' | tr -d ' ,' | xargs)

    # 写入报告
    echo "【NVME盘】 [NVME0N1] ${NVME_MODEL}" >> $REPORT_FILE
    echo "  - 容量: ${NVME_CAP:-N/A} | 寿命: ${NVME_LIFE} (已读: ${NVME_READ_TB:-N/A}, 已写: ${NVME_WRITE_TB:-N/A}) | 温度: ${NVME_TEMP:-N/A}°C" >> $REPORT_FILE
    echo "  - 状态: 通电 ${NVME_POWER_ON:-N/A} 次 | 不安全断电 ${NVME_UNSAFE_OFF:-N/A} 次 | 累计运行 ${NVME_HOURS:-N/A} 小时" >> $REPORT_FILE
    echo "" >> $REPORT_FILE
fi

# ==================== 2. SATA 盘采集 (/dev/sda) ====================
SATA_DEV="/dev/sda"
if [ -b "$SATA_DEV" ]; then
    SATA_MODEL=$(lsblk -d -n -o MODEL $SATA_DEV 2>/dev/null | xargs)
    SATA_SMART=$(smartctl -x $SATA_DEV 2>/dev/null)

    # 容量与通电时间
    SATA_CAP=$(lsblk -d -n -o SIZE $SATA_DEV 2>/dev/null | xargs)
    [ -z "$SATA_CAP" ] && SATA_CAP=$(echo "$SATA_SMART" | grep -i "User Capacity:" | awk -F'[' '{print $2}' | tr -d ']' | xargs)

    SATA_HOURS=$(echo "$SATA_SMART" | grep -iE "Power_On_Hours|Power-on Hours" | awk '{print $NF}' | grep -oE '[0-9]+' | tail -n1)

    # 【新增】SATA 通电次数 / 不安全断电次数（原脚本缺失，正是每日/周报的重点跟踪项）
    # 通电次数 = 属性 12 Power_Cycle_Count；异常断电 = 属性 174 Unexpect_Power_Loss_Ct
    SATA_POWER_CYCLE=$(echo "$SATA_SMART" | grep -E "\b12 Power_Cycle_Count\b" | awk '{print $NF}')
    SATA_UNSAFE=$(echo "$SATA_SMART" | grep -E "\b174 Unexpect_Power_Loss_Ct\b" | awk '{print $NF}')
    # 兼容机械盘/部分固件：192 Power-Off_Retract_Count 也计入异常断电
    [ -z "$SATA_UNSAFE" ] && SATA_UNSAFE=$(echo "$SATA_SMART" | grep -E "\b192 Power-Off_Retract_Count\b" | awk '{print $NF}')

    # 温度
    SATA_TEMP=$(echo "$SATA_SMART" | grep -i "Current Temperature:" | head -n1 | awk '{print $3}')
    [ -z "$SATA_TEMP" ] && SATA_TEMP=$(echo "$SATA_SMART" | grep -E "194 Temperature_Celsius|190 Airflow_Temperature" | awk '{print $NF}' | head -n1)

    # --- 寿命多重提取 (去除前导零如 099 -> 99) ---
    # 【修复】devstat 行 "0x07 0x008 1  1  N--  Percentage Used Endurance Indicator"
    #         中第 3 列是 Size、第 4 列才是实际值。原 $3 取到 Size（当前盘碰巧也是 1 才没出错）
    SATA_USED=$(echo "$SATA_SMART" | grep -i "Percentage Used Endurance Indicator" | awk '{print $4}' | grep -oE '[0-9]+')
    if [ -n "$SATA_USED" ]; then
        SATA_LIFE="$((100 - SATA_USED))%"
    else
        SATA_WEAR=$(echo "$SATA_SMART" | grep -E "\b177 Wear_Leveling_Count\b" | awk '{print $4}' | sed 's/^0*//')
        if [ -n "$SATA_WEAR" ] && [ "$SATA_WEAR" -gt 0 ]; then
            SATA_LIFE="${SATA_WEAR}%"
        else
            SATA_LIFE="未知"
        fi
    fi

    # --- 读写总量提取 (devstat 优先，241/242 兜底；拿不到读取量则隐藏该字段) ---
    # 【修复】原 grep -oE '[0-9]{5,}' 要求至少 5 位数字，小数值会漏匹配；
    #         改为取整行最后一段数字，兼容 devstat "0x01  0x028  6  6338402530321  ---  Logical Sectors Read" 格式
    WRITE_SECTORS=$(echo "$SATA_SMART" | grep -i "Logical Sectors Written" | grep -oE '[0-9]+' | tail -n1)
    [ -z "$WRITE_SECTORS" ] && WRITE_SECTORS=$(echo "$SATA_SMART" | grep -E "\b241 Total_LBAs_Written\b" | awk '{print $NF}' | grep -oE '[0-9]+')

    READ_SECTORS=$(echo "$SATA_SMART" | grep -i "Logical Sectors Read" | grep -oE '[0-9]+' | tail -n1)
    [ -z "$READ_SECTORS" ] && READ_SECTORS=$(echo "$SATA_SMART" | grep -E "\b242 Total_LBAs_Read\b" | awk '{print $NF}' | grep -oE '[0-9]+')

    # 格式化读写统计
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
    echo "【SATA盘】 [SDA] ${SATA_MODEL:-SATA SSD}" >> $REPORT_FILE
    echo "  - 容量: ${SATA_CAP:-N/A} | 寿命: ${SATA_LIFE} (${IO_STAT_STR})" >> $REPORT_FILE
    echo "  - 状态: 通电 ${SATA_POWER_CYCLE:-N/A} 次 | 不安全断电 ${SATA_UNSAFE:-N/A} 次 | 累计通电 ${SATA_HOURS:-N/A} 小时 | 温度: ${SATA_TEMP:-N/A}°C" >> $REPORT_FILE
    echo "" >> $REPORT_FILE
fi

# ==================== 3. 实时 I/O 简报 ====================
if command -v iostat &> /dev/null; then
    echo "---------------- [实时 I/O 性能评估] ----------------" >> $REPORT_FILE
    # 【优化】-y 跳过"开机累计"那一轮，只输出 1 秒间隔采样（原输出两轮，首轮是开机均值无参考价值）
    iostat -x -d -y 1 2 >> $REPORT_FILE
    echo "" >> $REPORT_FILE
fi

# ==================== 4. 发送邮件与清理 ====================
cat $REPORT_FILE | mail -s "$SUBJECT" $RECIPIENT
rm -f $REPORT_FILE

