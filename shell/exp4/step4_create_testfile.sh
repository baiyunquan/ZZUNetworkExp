#!/usr/bin/env bash
# =============================================================
# 实验4 步骤4：在 H57C 上创建测试文件
# 对应指导书《实验4》步骤4
# 用法: sudo ./step4_create_testfile.sh
# 前置: 已执行 ./create_topology.sh create
# =============================================================
set -euo pipefail
NS_H57C="H57C"
SIZE=3500
FILE="/root/3500.dat"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -q "$NS_H57C" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }

echo "==> 在 H57C 上创建 $SIZE 字节测试文件"
ip netns exec "$NS_H57C" truncate -s "$SIZE" "$FILE"
echo "==> 校验文件大小"
ip netns exec "$NS_H57C" ls -l "$FILE"
ip netns exec "$NS_H57C" stat -c '%s 字节: %n' "$FILE"

# ------------------------------------------------------------
# 预期实验现象:
#   ls -l 输出 "-rw-r--r-- 1 root root 3500 ... /root/3500.dat"，
#   stat 显示 "3500 字节: /root/3500.dat"。
#   文件内容全为 0（truncate 稀疏文件），仅作为 TCP 传输载荷使用。
#   3500 字节的意义: 大于以太网 MSS（1460）但小于 MTU 可承载的两段，
#   传输时将产生多个 TCP 数据段（约 3 段），便于观察 TCP 分段与确认。
# ------------------------------------------------------------
