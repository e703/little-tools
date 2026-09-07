#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/auto-upgrade.log"

# 將後續所有輸出（包含標準輸出與錯誤）同步寫入 Log 檔案
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "Starting system upgrade: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

sudo apt-get update && \
sudo apt-get -y --auto-remove --purge full-upgrade && \
sudo apt-get -y --purge autoremove && \
sudo apt-get clean -y

echo "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
