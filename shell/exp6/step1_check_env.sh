#!/usr/bin/env bash
# =============================================================
# 实验6 步骤1：环境检查
# 对应指导书《实验6》步骤1 (1)-(3)
# 用法: sudo ./step1_check_env.sh
# =============================================================
set -u

echo "==> (1) 检查 root 权限"
[ "$(id -u)" -eq 0 ] && echo "    root 用户 ✓" || { echo "    [错误] 请用 sudo/su - root 执行" >&2; exit 1; }

echo "==> (2) 检查基础软件工具（本实验额外要求 nping）"
ip -V || exit 1
for cmd in wireshark tshark ncat nping traceroute ethtool; do
    command -v "$cmd" >/dev/null && echo "    $cmd ✓" || { echo "    [错误] $cmd 未安装（nping/ncat 属 nmap 包）" >&2; MISS=1; }
done
[ -n "${MISS:-}" ] && exit 1

echo "==> (3) 检查防火墙状态"
if systemctl is-active firewalld >/dev/null 2>&1; then
    systemctl stop firewalld; echo "    firewalld 已关闭 ✓"
else
    echo "    firewalld 未运行 ✓"
fi

echo "==> (4) 内核虚拟网络能力"
modinfo veth   >/dev/null 2>&1 && echo "    veth ✓"
modinfo bridge >/dev/null 2>&1 && echo "    bridge ✓"

# ------------------------------------------------------------
# 预期实验现象:
#   全部工具 ✓（相比实验5重点确认 nping——构造超长 UDP 报文触发分片）；
#   firewalld 关闭（避免干扰路由器重组/转发分片）。
# ------------------------------------------------------------
