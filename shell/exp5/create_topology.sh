#!/usr/bin/env bash
# =============================================================
# 实验5 步骤2（要求实现的脚本）：一键创建/验证/销毁实验5拓扑
# 拓扑与实验3完全相同: H56A - SW56A - RB - RA - RD - SW57C - H57C
# 对应指导书《实验5》步骤2 "可以直接采用实验3的网络拓扑脚本程序"
#
# 用法:
#   sudo ./create_topology.sh create
#   sudo ./create_topology.sh verify
#   sudo ./create_topology.sh destroy
# =============================================================
set -euo pipefail

NS_H56A="H56A"; NS_SW56A="SW56A"; NS_RB="RB"; NS_RA="RA"; NS_RD="RD"
NS_SW57C="SW57C"; NS_H57C="H57C"
BR_56A="br_SW56A"; BR_57C="br_SW57C"

V_H56A="ve-H56A";        V_SW56A_H56A="ve-SW56A-H56A"
V_RB_56A="ve-RB-SW56A";  V_SW56A_RB="ve-SW56A-RB"
V_RB_RA="ve-RB-RA";      V_RA_RB="ve-RA-RB"
V_RA_RD="ve-RA-RD";      V_RD_RA="ve-RD-RA"
V_RD_57C="ve-RD-SW57C";  V_SW57C_RD="ve-SW57C-RD"
V_H57C="ve-H57C";        V_SW57C_H57C="ve-SW57C-H57C"

IP_H56A="192.168.56.126/25"
IP_RB_56A="192.168.56.1/25"
IP_RB_RA="192.168.56.245/30"; IP_RA_RB="192.168.56.246/30"
IP_RA_RD="192.168.56.253/30"; IP_RD_RA="192.168.56.254/30"
IP_RD_57C="192.168.57.193/26"
IP_H57C="192.168.57.254/26"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root/sudo 执行" >&2; exit 1; }

ns_exists() { ip netns list | grep -qw "$1"; }

offload_off() {
    # 失败留痕（veth 的 rx off 可能被内核拒绝，属已知限制），offload 状态由 step2 脚本复查
    if ! ip netns exec "$1" ethtool -K "$2" rx off tx off gso off tso off gro off 2>/dev/null; then
        echo "[警告] $1.$2 offload 关闭失败（检查 ethtool 是否安装）" >&2
    fi
}

do_create() {
    # 幂等性保护: 若拓扑已存在，先销毁旧拓扑再重建
    if ns_exists "$NS_H56A" || ns_exists "$NS_SW56A" || ns_exists "$NS_RB" \
       || ns_exists "$NS_RA" || ns_exists "$NS_RD" || ns_exists "$NS_SW57C" || ns_exists "$NS_H57C"; then
        echo "==> 检测到已有同名命名空间，先销毁旧拓扑"
        do_destroy
    fi
    # 创建中途失败时回滚，避免留下半成品状态
    trap 'echo "[错误] 创建失败，回滚已创建的资源" >&2; do_destroy' ERR

    echo "==> 创建 7 个网络命名空间"
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW57C" "$NS_H57C"; do
        ip netns add "$ns"
        ip netns exec "$ns" ip link set lo up
    done

    echo "==> 创建网桥（交换机）"
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

    echo "==> 交换机侧 VETH 绑定网桥"
    ip netns exec "$NS_SW56A" ip link set "$V_SW56A_H56A" master "$BR_56A"
    ip netns exec "$NS_SW56A" ip link set "$V_SW56A_RB"   master "$BR_56A"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_RD"   master "$BR_57C"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_H57C" master "$BR_57C"

    echo "==> 配置 IP 并启用全部接口"
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

    echo "==> 路由器开启转发 + 配置静态路由"
    for ns in "$NS_RB" "$NS_RA" "$NS_RD"; do
        ip netns exec "$ns" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    done
    ip netns exec "$NS_H56A" ip route add default via 192.168.56.1
    ip netns exec "$NS_H57C" ip route add default via 192.168.57.193
    ip netns exec "$NS_RB" ip route add 192.168.57.192/26 via 192.168.56.246
    ip netns exec "$NS_RA" ip route add 192.168.56.0/25   via 192.168.56.245
    ip netns exec "$NS_RA" ip route add 192.168.57.192/26 via 192.168.56.254
    ip netns exec "$NS_RD" ip route add 192.168.56.0/25 via 192.168.56.253

    echo "==> 关闭 offload（实验要求）"
    offload_off "$NS_H56A" "$V_H56A";  offload_off "$NS_H57C" "$V_H57C"
    offload_off "$NS_RB" "$V_RB_56A";  offload_off "$NS_RB" "$V_RB_RA"
    offload_off "$NS_RA" "$V_RA_RB";   offload_off "$NS_RA" "$V_RA_RD"
    offload_off "$NS_RD" "$V_RD_RA";   offload_off "$NS_RD" "$V_RD_57C"

    echo "==> 拓扑创建完成"
    trap - ERR
}

do_verify() {
    verify_fail=0
    echo "==> 命名空间列表"; ip netns list
    echo "==> 网桥绑定"
    # bridge link show 不支持裸设备名过滤（参数被静默忽略），改用 ip link show master
    ip netns exec "$NS_SW56A" ip link show master "$BR_56A"
    ip netns exec "$NS_SW57C" ip link show master "$BR_57C"
    echo "==> 各节点地址与路由"
    for ns in "$NS_H56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_H57C"; do
        echo "--- $ns ---"
        ip netns exec "$ns" ip -4 -br addr
        ip netns exec "$ns" ip route
    done
    echo "==> 可达性与转发路径"
    if ip netns exec "$NS_H56A" ping -c 4 192.168.57.254; then
        echo "    IPv4 跨路由可达 ✓"
    else
        echo "    ping 失败 ✗（检查接口 up / IP / 静态路由 / ip_forward）" >&2
        verify_fail=1
    fi
    ip netns exec "$NS_H56A" traceroute 192.168.57.254 || verify_fail=1
    [ "$verify_fail" -eq 0 ] && echo "==> 验证全部通过 ✓" || { echo "==> 验证存在失败项 ✗" >&2; exit 1; }
}

do_destroy() {
    echo "==> 终止命名空间内的残留进程（ncat/tshark），再删除命名空间"
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW57C" "$NS_H57C"; do
        if ns_exists "$ns"; then
            pids=$(ip netns pids "$ns" 2>/dev/null || true)
            [ -n "$pids" ] && kill $pids 2>/dev/null || true
        fi
    done
    sleep 1
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW57C" "$NS_H57C"; do
        ip netns del "$ns" 2>/dev/null || true
    done
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
# 预期实验现象:（与实验3一致）
#   verify: 7 个命名空间；网桥各绑 2 接口；地址/路由与规划一致；
#     ping -c 4 -> 4 received, 0% packet loss；
#     traceroute -> 4 跳: RB(192.168.56.1) -> RA(192.168.56.246)
#       -> RD(192.168.56.254) -> H57C(192.168.57.254)（TTL=3 的包在 RD
#       处到期，RD 回 ICMP Time Exceeded，故第 3 跳是 RD）。
#   注意（指导书原文）: 每次重新执行 create，VETH 接口的 MAC 地址
#     有可能不同，记录信息时以当次 verify 输出为准。
# ------------------------------------------------------------
