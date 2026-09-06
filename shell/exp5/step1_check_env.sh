#!/usr/bin/env bash
# =============================================================
# 实验5 步骤1：环境检查
# 对应指导书《实验5》步骤1 (1)-(3)
# 用法: sudo ./step1_check_env.sh
# =============================================================
set -u

echo "==> (1) 检查 root 权限"
[ "$(id -u)" -eq 0 ] && echo "    root 用户 ✓" || { echo "    [错误] 请用 sudo/su - root 执行" >&2; exit 1; }

echo "==> (2) 检查基础软件工具"
ip -V || exit 1
if command -v tc >/dev/null; then
    echo "    tc ✓（netem 丢包模拟必需）"
else
    echo "    [错误] tc 未安装（属 iproute2）" >&2
    MISS=1
fi
for cmd in wireshark tshark ncat traceroute ethtool truncate; do
    if command -v "$cmd" >/dev/null; then
        echo "    $cmd ✓"
    else
        echo "    [错误] $cmd 未安装（ncat/nping 属 nmap 包；truncate 属 coreutils）" >&2
        MISS=1
    fi
done
if [ -n "${MISS:-}" ]; then
    echo "==> 环境检查存在失败项，先修复再进入步骤2 ✗" >&2
    exit 1
fi
echo "==> 基础软件工具检查通过 ✓"

echo "==> 检查内核 netem 模块"
if modinfo sch_netem >/dev/null 2>&1; then
    echo "    sch_netem ✓"
else
    echo "    [警告] sch_netem 模块未找到，可能编译进内核，执行时验证" >&2
fi

echo "==> (3) 检查防火墙状态"
if systemctl is-active firewalld >/dev/null 2>&1; then
    systemctl stop firewalld; echo "    firewalld 已关闭 ✓"
else
    echo "    firewalld 未运行 ✓"
fi

# ------------------------------------------------------------
# 预期实验现象:
#   全部工具 ✓（相比实验4重点确认 tc 与 sch_netem——netem 丢包模拟用）；
#   firewalld 关闭。
# ------------------------------------------------------------
