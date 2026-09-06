#!/usr/bin/env bash
# =============================================================
# 实验6 步骤3：修改核心链路 MTU，制造 IP 分片条件
# 对应指导书《实验6》步骤3
# 用法: sudo ./step3_set_mtu.sh [MTU，默认1000]
# =============================================================
set -euo pipefail
NS_RA="RA"; NS_RB="RB"; NS_H56A="H56A"
IF_RA="ve-RA-RB"    # RA 侧连接 RB 的接口
IF_RB="ve-RB-RA"    # RB 侧连接 RA 的接口
MTU="${1:-1000}"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -qw "$NS_RA" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }

# MTU 校验: IPv6 要求最小 MTU 1280，本实验纯 IPv4 可低于此值，但给出警告
if ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 68 ] || [ "$MTU" -gt 1500 ]; then
    echo "[错误] MTU 必须是 68~1500 的整数，当前为: $MTU" >&2
    exit 1
fi
if [ "$MTU" -lt 1280 ]; then
    echo "[警告] MTU=$MTU 低于 IPv6 最小 MTU（1280），该链路上 IPv6 将无法工作（本实验纯 IPv4 不受影响）" >&2
fi

echo "==> 修改 RA 侧接口 $IF_RA 的 MTU 为 $MTU"
ip netns exec "$NS_RA" ip link set dev "$IF_RA" mtu "$MTU"
echo "==> 修改 RB 侧接口 $IF_RB 的 MTU 为 $MTU"
ip netns exec "$NS_RB" ip link set dev "$IF_RB" mtu "$MTU"

echo "==> 验证 MTU 生效"
ip netns exec "$NS_RA" ip link show "$IF_RA" | grep -oE 'mtu [0-9]+'
ip netns exec "$NS_RB" ip link show "$IF_RB" | grep -oE 'mtu [0-9]+'

echo "==> 连通性回归测试（小包不受 MTU 影响）"
ip netns exec "$NS_H56A" ping -c 2 192.168.57.254

# ------------------------------------------------------------
# 预期实验现象:
#   1. ip link show 输出 "mtu 1000"（两侧一致）；
#   2. 小包 ping 仍然 0% 丢包（MTU 缩小不影响小报文转发）；
#   3. 后续步骤6 发送 1400 字节数据的 UDP 报文（IP 总长 1428 字节）
#      超过 1000 字节 MTU，将在 RB 处触发 IP 分片。
#   注意: 只需改 RB-RA 链路两侧（指导书指定），其他链路保持 1500。
# ------------------------------------------------------------
