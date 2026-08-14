#!/bin/bash

# ================= 配置区 =================
GATEWAY_IP="172.16.0.1"       # ⚠️ 替换为你局域网软路由/网关 VM 的真实 IP
GATEWAY_VMID="100"            # ⚠️ 替换为你的软路由 VM 在 PVE 中的 VMID（如 100）
PUBLIC_TARGETS=("223.5.5.5" "1.1.1.1") # 外网双 IP 冗余探测

MAX_FAILURES=10                # 连续失败次数阈值
FAIL_COUNTER_FILE="/tmp/net_watchdog_fail_count"
LOG_FILE="/var/log/net_watchdog.log"
# =========================================

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 1. 第一步：先检查 PVE 到网关 VM 的局域网连通性
if ! ping -c 2 -W 2 "$GATEWAY_IP" > /dev/null 2>&1; then
    log_message "Cannot reach Gateway VM ($GATEWAY_IP). Checking VM status..."
    
    # 检查网关 VM 是否处于 running 状态
    VM_STATUS=$(qm status "$GATEWAY_VMID" 2>/dev/null | awk '{print $2}')
    
    if [ "$VM_STATUS" != "running" ]; then
        log_message "Gateway VM ($GATEWAY_VMID) is not running! Starting it..."
        qm start "$GATEWAY_VMID"
    else
        log_message "Gateway VM is running but unresponsive. Resetting Gateway VM..."
        qm reset "$GATEWAY_VMID"
    fi
    exit 0
fi

# 2. 第二步：网关正常，再检查外网连通性（只要一个能通即算正常）
public_online=false
for target in "${PUBLIC_TARGETS[@]}"; do
    if ping -c 2 -W 2 "$target" > /dev/null 2>&1; then
        public_online=true
        break
    fi
done

if [ "$public_online" = true ]; then
    # 网络正常，重置计数器
    if [ -f "$FAIL_COUNTER_FILE" ]; then
        rm -f "$FAIL_COUNTER_FILE"
        log_message "Network recovered. Failure counter reset."
    fi
else
    # 外网异常，增加计数
    FAIL_COUNT=$(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$FAIL_COUNTER_FILE"

    log_message "Gateway reachable, but Public Internet unreachable ($FAIL_COUNT/$MAX_FAILURES)."

    # 达到一半阈值（5次）：先尝试软重启网关 VM 和 PVE 网络
    if [ "$FAIL_COUNT" -eq $((MAX_FAILURES / 2)) ]; then
        log_message "Attempting to restart PVE networking & Gateway VM..."
        systemctl restart networking > /dev/null 2>&1
        qm reboot "$GATEWAY_VMID" > /dev/null 2>&1
    fi

    # 达到最大阈值（10次）：仅重启网关 VM，坚决不重启 PVE 宿主机
    if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
        log_message "Internet down after $MAX_FAILURES checks. Hard resetting Gateway VM ($GATEWAY_VMID)..."
        rm -f "$FAIL_COUNTER_FILE"
        qm reset "$GATEWAY_VMID"
    fi
fi
