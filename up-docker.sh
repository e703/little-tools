#!/usr/bin/env bash

# 遇到错误立即停止执行
set -e

echo "=== [1/5] 开始执行系统自动更新 ==="
cd ~
auto-upgrade.sh

echo "=== [2/5] 运行 CLI Proxy API 安装/更新程序 ==="
./cliproxyapi-installer/cliproxyapi-installer

echo "=== [3/5] 更新并重启 Docker 容器服务 ==="
echo "--> 更新 aiclient-2-api..."
cd ~/aiclient-2-api/
docker compose pull && docker compose up -d

echo "--> 更新 cpa-manager-plus..."
cd ~/cpa-manager-plus/
docker compose pull && docker compose up -d

echo "=== [4/5] 检查服务端口监听状态 (8317 & 18317) ==="
sleep 3
if ss -tlnp | grep -E "8317|18317" > /dev/null; then
    echo "✅ 端口检查通过，以下是监听详情："
    ss -tlnp | grep -E "8317|18317"
else
    echo "⚠️ 警告：未检测到 8317 或 18317 端口在监听，请检查容器日志 (docker compose logs)"
fi

echo "=== [5/5] 清理未使用的 Docker 镜像与容器缓存 ==="
docker system prune -a -f

echo "=== [6/6] 查看当前系统资源状态 ==="
echo "------------------- 磁盘空间 -------------------"
df -h
echo -e "\n------------------- 内存使用 -------------------"
free -h

echo -e "\n=============================================="
echo "          🎉 所有维护任务已成功完成！          "
echo "=============================================="
