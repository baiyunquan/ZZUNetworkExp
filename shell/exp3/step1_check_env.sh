#!/usr/bin/env bash
# =============================================================
# 实验3 步骤1：环境检查
# 对应指导书《实验3》步骤1 (1)-(3)
# 用法: sudo ./step1_check_env.sh
# =============================================================
set -u

echo "==> (1) 检查 root 权限"
[ "$(id -u)" -eq 0 ] && echo "    root 用户 ✓" || { echo "    [错误] 请用 sudo/su - root 执行" >&2; exit 1; }

echo "==> (2) 检查基础软件工具"
ip -V || exit 1
for cmd in wireshark tshark ncat traceroute ethtool; do
    if command -v "$cmd" >/dev/null; then
        echo "    $cmd ✓"
    else
        echo "    [错误] $cmd 未安装（openEuler: dnf install nmap traceroute ethtool / Arch: pacman -S nmap ethtool）" >&2
        MISS=1
    fi
done
[ -n "${MISS:-}" ] && exit 1

echo "==> (3) 检查防火墙状态"
if systemctl is-active firewalld >/dev/null 2>&1; then
    echo "    firewalld 运行中，正在关闭（避免干扰虚拟路由器重组 IP 分片）..."
    systemctl stop firewalld
    echo "    已关闭 ✓"
else
    echo "    firewalld 未运行 ✓"
fi

echo "==> (4) 检查内核虚拟网络能力"
modinfo veth   >/dev/null 2>&1 && echo "    veth ✓"
modinfo bridge >/dev/null 2>&1 && echo "    bridge ✓"

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 输出 "root 用户 ✓"；
#   (2) ip -V 输出版本；ncat/traceroute/ethtool/Wireshark 均显示 ✓
#       （ncat 属 nmap 包，nping 同包，实验6 会用到）；
#   (3) firewalld 显示"未运行 ✓"或被自动关闭；
#       若防火墙未关闭，UDP 报文可能被丢弃、分片重组异常，导致 ping 通
#       但 ncat 通信失败；
#   (4) veth/bridge 模块均存在。
#   全部通过后才能进入步骤2。
# ------------------------------------------------------------
