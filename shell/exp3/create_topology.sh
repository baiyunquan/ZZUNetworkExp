#!/usr/bin/env bash
# =============================================================
# 实验3 步骤2（要求实现的脚本）：一键创建/验证/销毁实验3拓扑
# 拓扑: H56A - SW56A - RB - RA - RD - SW57C - H57C（2主机2交换机3路由器）
# 对应指导书《实验3》步骤2 "借助AI工具，搭建虚拟网络拓扑并验证"
#
# 用法:
#   sudo ./create_topology.sh create    # 创建拓扑+IP+静态路由+关闭offload
#   sudo ./create_topology.sh verify    # 验证拓扑/地址/路由/连通性
#   sudo ./create_topology.sh destroy   # 销毁拓扑
# =============================================================
set -euo pipefail

# ---- 命名空间 ----
NS_H56A="H56A"; NS_SW56A="SW56A"; NS_RB="RB"; NS_RA="RA"; NS_RD="RD"
NS_SW57C="SW57C"; NS_H57C="H57C"

# ---- 网桥 ----
BR_56A="br_SW56A"; BR_57C="br_SW57C"

# ---- VETH 接口 ----
V_H56A="ve-H56A";        V_SW56A_H56A="ve-SW56A-H56A"
V_RB_56A="ve-RB-SW56A";  V_SW56A_RB="ve-SW56A-RB"
V_RB_RA="ve-RB-RA";      V_RA_RB="ve-RA-RB"
V_RA_RD="ve-RA-RD";      V_RD_RA="ve-RD-RA"
V_RD_57C="ve-RD-SW57C";  V_SW57C_RD="ve-SW57C-RD"
V_H57C="ve-H57C";        V_SW57C_H57C="ve-SW57C-H57C"

# ---- IP 规划（指导书固定地址）----
IP_H56A="192.168.56.126/25"     # 主机H56A
IP_RB_56A="192.168.56.1/25"     # RB 连 SW56A 侧
NET_RB_RA="192.168.56.244/30"   # RB-RA 互连网段
IP_RB_RA="192.168.56.245/30"    # RB 侧（/30 可用地址）
IP_RA_RB="192.168.56.246/30"    # RA 侧
NET_RA_RD="192.168.56.252/30"   # RA-RD 互连网段
IP_RA_RD="192.168.56.253/30"    # RA 侧
IP_RD_RA="192.168.56.254/30"    # RD 侧
IP_RD_57C="192.168.57.193/26"   # RD 连 SW57C 侧
IP_H57C="192.168.57.254/26"     # 主机H57C

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root/sudo 执行" >&2; exit 1; }

offload_off() {  # 关闭网卡 offload，保证校验和/分片由 CPU 计算
    local ns="$1" ifname="$2"
    ip netns exec "$ns" ethtool -K "$ifname" rx off tx off gso off tso off gro off 2>/dev/null || true
}

do_create() {
    echo "==> 创建 7 个网络命名空间"
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW57C" "$NS_H57C"; do
        ip netns add "$ns"
    done

    echo "==> 在交换机命名空间内创建网桥"
    ip netns exec "$NS_SW56A" ip link add "$BR_56A" type bridge
    ip netns exec "$NS_SW56A" ip link set "$BR_56A" up
    ip netns exec "$NS_SW57C" ip link add "$BR_57C" type bridge
    ip netns exec "$NS_SW57C" ip link set "$BR_57C" up

    echo "==> 创建 6 对 VETH 并迁移"
    ip link add "$V_H56A"     type veth peer name "$V_SW56A_H56A"
    ip link add "$V_RB_56A"   type veth peer name "$V_SW56A_RB"
    ip link add "$V_RB_RA"    type veth peer name "$V_RA_RB"
    ip link add "$V_RA_RD"    type veth peer name "$V_RD_RA"
    ip link add "$V_RD_57C"   type veth peer name "$V_SW57C_RD"
    ip link add "$V_H57C"     type veth peer name "$V_SW57C_H57C"

    ip link set "$V_H56A"       netns "$NS_H56A"
    ip link set "$V_SW56A_H56A" netns "$NS_SW56A"
    ip link set "$V_RB_56A"     netns "$NS_RB"
    ip link set "$V_SW56A_RB"   netns "$NS_SW56A"
    ip link set "$V_RB_RA"      netns "$NS_RB"
    ip link set "$V_RA_RB"      netns "$NS_RA"
    ip link set "$V_RA_RD"      netns "$NS_RA"
    ip link set "$V_RD_RA"      netns "$NS_RD"
    ip link set "$V_RD_57C"     netns "$NS_RD"
    ip link set "$V_SW57C_RD"   netns "$NS_SW57C"
    ip link set "$V_H57C"       netns "$NS_H57C"
    ip link set "$V_SW57C_H57C" netns "$NS_SW57C"

    echo "==> 交换机侧 VETH 绑定网桥并启用"
    ip netns exec "$NS_SW56A" ip link set "$V_SW56A_H56A" master "$BR_56A"
    ip netns exec "$NS_SW56A" ip link set "$V_SW56A_RB"   master "$BR_56A"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_RD"   master "$BR_57C"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_H57C" master "$BR_57C"
    for i in "$V_SW56A_H56A" "$V_SW56A_RB"; do ip netns exec "$NS_SW56A" ip link set "$i" up; done
    for i in "$V_SW57C_RD" "$V_SW57C_H57C"; do ip netns exec "$NS_SW57C" ip link set "$i" up; done

    echo "==> 配置各节点 IP 并启用接口"
    ip netns exec "$NS_H56A" ip addr add "$IP_H56A"   dev "$V_H56A"
    ip netns exec "$NS_RB"   ip addr add "$IP_RB_56A" dev "$V_RB_56A"
    ip netns exec "$NS_RB"   ip addr add "$IP_RB_RA"  dev "$V_RB_RA"
    ip netns exec "$NS_RA"   ip addr add "$IP_RA_RB"  dev "$V_RA_RB"
    ip netns exec "$NS_RA"   ip addr add "$IP_RA_RD"  dev "$V_RA_RD"
    ip netns exec "$NS_RD"   ip addr add "$IP_RD_RA"  dev "$V_RD_RA"
    ip netns exec "$NS_RD"   ip addr add "$IP_RD_57C" dev "$V_RD_57C"
    ip netns exec "$NS_H57C" ip addr add "$IP_H57C"   dev "$V_H57C"
    for spec in \
        "$NS_H56A $V_H56A" "$NS_SW56A $V_SW56A_H56A" "$NS_SW56A $V_SW56A_RB" \
        "$NS_RB $V_RB_56A" "$NS_RB $V_RB_RA" "$NS_RA $V_RA_RB" "$NS_RA $V_RA_RD" \
        "$NS_RD $V_RD_RA" "$NS_RD $V_RD_57C" "$NS_SW57C $V_SW57C_RD" \
        "$NS_SW57C $V_SW57C_H57C" "$NS_H57C $V_H57C"; do
        ip netns exec "${spec%% *}" ip link set "${spec#* }" up
    done
    ip netns exec "$NS_SW56A" ip link set "$BR_56A" up
    ip netns exec "$NS_SW57C" ip link set "$BR_57C" up

    echo "==> 路由器开启转发功能"
    for ns in "$NS_RB" "$NS_RA" "$NS_RD"; do
        ip netns exec "$ns" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    done

    echo "==> 配置静态路由"
    # 主机默认网关
    ip netns exec "$NS_H56A" ip route add default via 192.168.56.1
    ip netns exec "$NS_H57C" ip route add default via 192.168.57.193
    # RB: 去往 57 网段经 RA
    ip netns exec "$NS_RB" ip route add 192.168.57.192/26 via 192.168.56.246
    # RA: 两个局域网分别经 RB / RD
    ip netns exec "$NS_RA" ip route add 192.168.56.0/25   via 192.168.56.245
    ip netns exec "$NS_RA" ip route add 192.168.57.192/26 via 192.168.56.254
    # RD: 去往 56 网段经 RA
    ip netns exec "$NS_RD" ip route add 192.168.56.0/25 via 192.168.56.253

    echo "==> 关闭所有主机/路由器 VETH 的 offload（实验要求）"
    offload_off "$NS_H56A" "$V_H56A"
    offload_off "$NS_H57C" "$V_H57C"
    offload_off "$NS_RB"   "$V_RB_56A";  offload_off "$NS_RB" "$V_RB_RA"
    offload_off "$NS_RA"   "$V_RA_RB";   offload_off "$NS_RA" "$V_RA_RD"
    offload_off "$NS_RD"   "$V_RD_RA";   offload_off "$NS_RD" "$V_RD_57C"

    echo "==> 拓扑创建完成"
}

do_verify() {
    echo "==> 命名空间列表"
    ip netns list
    echo "==> 交换机网桥绑定"
    ip netns exec "$NS_SW56A" bridge link show "$BR_56A"
    ip netns exec "$NS_SW57C" bridge link show "$BR_57C"
    echo "==> 各节点地址与路由"
    for ns in "$NS_H56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_H57C"; do
        echo "--- $ns ---"
        ip netns exec "$ns" ip -4 -br addr
        ip netns exec "$ns" ip route
    done
    echo "==> 路由器转发状态"
    for ns in "$NS_RB" "$NS_RA" "$NS_RD"; do
        echo "    $ns ip_forward=$(ip netns exec "$ns" sysctl -n net.ipv4.ip_forward)"
    done
    echo "==> 可达性测试（H56A -> H57C）"
    ip netns exec "$NS_H56A" ping -c 4 192.168.57.254
    echo "==> 转发路径（H56A -> H57C）"
    ip netns exec "$NS_H56A" traceroute 192.168.57.254
}

do_destroy() {
    echo "==> 删除全部命名空间"
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW57C" "$NS_H57C"; do
        ip netns del "$ns" 2>/dev/null || true
    done
    echo "==> 兜底清理主空间残留 VETH"
    for v in "$V_H56A" "$V_RB_56A" "$V_RB_RA" "$V_RA_RD" "$V_RD_57C" "$V_H57C"; do
        ip link del "$v" 2>/dev/null || true
    done
    echo "==> 已清理"
}

case "${1:-}" in
    create)  do_create  ;;
    verify)  do_verify  ;;
    destroy) do_destroy ;;
    *) echo "用法: $0 {create|verify|destroy}" >&2; exit 1 ;;
esac

# ------------------------------------------------------------
# 预期实验现象:
#   create:
#     依次输出各步骤提示，无报错结束。
#   verify:
#     1) ip netns list 列出 7 个命名空间；
#     2) 两个网桥各绑定 2 个 VETH 接口且状态 up；
#     3) H56A=192.168.56.126/25、H57C=192.168.57.254/26，
#        RB/RA/RD 各接口地址与规划一致，默认路由/静态路由正确；
#     4) 三台路由器 ip_forward=1；
#     5) ping -c 4 输出 "4 packets transmitted, 4 received, 0% packet loss"，
#        说明跨三个路由器端到端可达；
#     6) traceroute 输出 3 跳: 192.168.56.1(RB) -> 192.168.56.246(RA)
#        -> 192.168.57.254(H57C)，与拓扑路径 RB-RA-RD 一致。
#   destroy:
#     全部命名空间与 VETH 清理干净，系统恢复初始状态。
# ------------------------------------------------------------
