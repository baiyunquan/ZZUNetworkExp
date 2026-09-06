#!/usr/bin/env bash
# =============================================================
# 实验1 步骤1：环境检查
# 对应指导书《实验1》步骤1
# 用法: sudo ./step1_check_env.sh
# =============================================================
set -u

echo "==> (1) 检查当前用户权限"
if [ "$(id -u)" -eq 0 ]; then
    echo "    当前为 root 用户 ✓"
else
    echo "    [错误] 请先切换到 root 用户：su - root，或使用 sudo 执行本脚本" >&2
    exit 1
fi

echo "==> (2) 检查 iproute2（ip 命令）"
ip -V || { echo "    [错误] ip 命令不可用，请安装 iproute2/iproute" >&2; exit 1; }

echo "==> (3) 检查 Wireshark"
if wireshark --version >/dev/null 2>&1; then
    wireshark --version | head -1
else
    echo "    [警告] Wireshark 未安装（openEuler: dnf install wireshark / Debian系: apt install wireshark）" >&2
fi

echo "==> (4) 检查内核虚拟网络能力（netns / veth / bridge）"
ls /proc/self/ns/net >/dev/null 2>&1 && echo "    网络命名空间支持 ✓"
modinfo veth   >/dev/null 2>&1 && echo "    veth 模块 ✓"
modinfo bridge >/dev/null 2>&1 && echo "    bridge 模块 ✓"

echo "==> (5) 检查辅助工具（traceroute / tshark）"
command -v traceroute >/dev/null && echo "    traceroute ✓" || echo "    [警告] traceroute 未安装"
command -v tshark     >/dev/null && echo "    tshark ✓（无 GUI 时可用命令行抓包）" || echo "    [提示] tshark 未安装"

# ------------------------------------------------------------
# 预期实验现象:
#   1. 输出 "当前为 root 用户 ✓"，说明具备管理权限；
#   2. ip -V 输出版本号，如 "ip utility, iproute2-6.x.x, libbpf x.x.x"，
#      说明 iproute2 安装正常；
#   3. wireshark --version 输出 "Wireshark 4.x.x ..."，说明 Wireshark 安装正常；
#   4. netns/veth/bridge 三项均显示 ✓，说明内核支持虚拟网络环境搭建；
#   5. 若任一项缺失，按脚本提示安装后重新执行，直到全部通过。
# ------------------------------------------------------------
