#!/usr/bin/env bash
# =============================================================
# 实验1 步骤2：创建虚拟网络拓扑（手动命令版）
# 拓扑: 主机HA --交换机SWA-- 主机HB
# 对应指导书《实验1》步骤2
# 用法: sudo ./step2_create_topology.sh
# =============================================================
set -euo pipefail

NS_HA="HA"; NS_HB="HB"; NS_SWA="SWA"
BR="br-swa"
VETH_HA="ve-ha-swa"; VETH_HA_PEER="ve-swa-ha"
VETH_HB="ve-hb-swa"; VETH_HB_PEER="ve-swa-hb"

echo "==> (1) 创建三个网络命名空间（HA / HB / SWA）"
ip netns add "$NS_HA"
ip netns add "$NS_HB"
ip netns add "$NS_SWA"
ip netns list

echo "==> (2) 在 SWA 内创建并启用网桥 $BR"
ip netns exec "$NS_SWA" ip link add "$BR" type bridge
ip netns exec "$NS_SWA" ip link set "$BR" up
ip netns exec "$NS_SWA" ip link show

echo "==> (3) 创建两对 VETH 对等接口"
ip link add "$VETH_HA" type veth peer name "$VETH_HA_PEER"
ip link add "$VETH_HB" type veth peer name "$VETH_HB_PEER"
ip link show | grep -E "^[@0-9]+: ${VETH_HA}|${VETH_HB}" || ip link show

echo "==> (4) 将 VETH 接口迁移到对应命名空间"
ip link set "$VETH_HA" netns "$NS_HA"
ip link set "$VETH_HA_PEER" netns "$NS_SWA"
ip link set "$VETH_HB" netns "$NS_HB"
ip link set "$VETH_HB_PEER" netns "$NS_SWA"
for ns in "$NS_HA" "$NS_HB" "$NS_SWA"; do
    echo "--- $ns 内的网络接口 ---"
    ip netns exec "$ns" ip link show
done

echo "==> (5) 将交换机侧 VETH 绑定到网桥并启用"
ip netns exec "$NS_SWA" ip link set "$VETH_HA_PEER" master "$BR"
ip netns exec "$NS_SWA" ip link set "$VETH_HB_PEER" master "$BR"
ip netns exec "$NS_SWA" ip link set "$VETH_HA_PEER" up
ip netns exec "$NS_SWA" ip link set "$VETH_HB_PEER" up
ip netns exec "$NS_SWA" bridge link show "$BR"

# ------------------------------------------------------------
# 预期实验现象:
#   (1) ip netns list 显示三行: HA / HB / SWA（可能带 id 编号）；
#   (2) SWA 内 ip link show 出现 br-swa，且状态为 up；
#   (3) 主空间 ip link show 出现 4 个以 ve 开头的 VETH 接口；
#   (4) 迁移后: HA 内可见 ve-ha-swa，HB 内可见 ve-hb-swa，
#       SWA 内可见 ve-swa-ha、ve-swa-hb（各自还有 lo）；
#   (5) bridge link show br-swa 显示两个 VETH 接口已绑定且状态 up，
#       表示两台主机已通过"交换机"完成二层连接。
#   注意: 此时接口均未配 IP，主机间尚不能 ping 通，属正常现象。
# ------------------------------------------------------------
