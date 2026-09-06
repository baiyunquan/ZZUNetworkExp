#!/usr/bin/env bash
# =============================================================
# 实验5 步骤4：修改两台主机的 TCP 内核参数
# 对应指导书《实验5》步骤4 (3)(4)
# 用法: sudo ./step4_tcp_tuning.sh
# 作用: 1) 调小 TCP 接收缓存 -> 降低接收窗口，方便观测重传；
#       2) 关闭 SACK -> 避免基于 SACK 的选择性重传，保证观测单一。
# =============================================================
set -euo pipefail
NS_H56A="H56A"; NS_H57C="H57C"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -qw "$NS_H56A" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }
ip netns list | grep -qw "$NS_H57C" || { echo "[错误] 拓扑未创建（缺少 H57C），先运行 create_topology.sh create" >&2; exit 1; }

for ns in "$NS_H56A" "$NS_H57C"; do
    echo "==> $ns: 调整 TCP 接收缓存 (4096 65536 65536)"
    ip netns exec "$ns" sysctl -w net.ipv4.tcp_rmem='4096 65536 65536'
    echo "==> $ns: 关闭 SACK"
    ip netns exec "$ns" sysctl -w net.ipv4.tcp_sack=0
    echo "==> $ns: 回读校验"
    echo "    tcp_rmem = $(ip netns exec "$ns" sysctl -n net.ipv4.tcp_rmem)"
    echo "    tcp_sack = $(ip netns exec "$ns" sysctl -n net.ipv4.tcp_sack)"
done

# ------------------------------------------------------------
# 预期实验现象:
#   1. sysctl -w 输出确认行:
#        net.ipv4.tcp_rmem = 4096 65536 65536
#        net.ipv4.tcp_sack = 0
#   2. 回读值与设置一致；
#   3. 后续 TCP 握手的 SYN 报文中不再出现 SACK-permitted 选项
#      （tshark 字段 tcp.options.sack_perm 为空）；
#      接收窗口上限被 tcp_rmem max=65536 约束（即使有窗口扩大选项，
#      实际窗口也不会超出此上限），传输 100K 文件时窗口反复
#      填满/腾空，丢包后更易观测重传。
#   注意: 这些参数仅对命名空间内生效，destroy 后随命名空间消失，
#   不影响宿主机。
# ------------------------------------------------------------
