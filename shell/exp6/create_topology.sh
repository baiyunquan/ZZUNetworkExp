#!/usr/bin/env bash
# =============================================================
# 实验6 步骤2（要求实现的脚本）：一键创建/验证/销毁实验6大拓扑
# 拓扑: 4主机 + 4交换机 + 5路由器 + 1互联网出口
#   H56A-SW56A-RB-RA-RC-SW57A-H57A
#                     RA-RD-SW57C-H57C
#                          RE-SW57B-H57B
#   RA - 出口网关(192.168.99.1)
# 对应指导书《实验6》步骤2
#
# 用法:
#   sudo ./create_topology.sh create
#   sudo ./create_topology.sh verify
#   sudo ./create_topology.sh destroy
# =============================================================
set -euo pipefail

# ---- 命名空间 ----
NS_H56A="H56A"; NS_SW56A="SW56A"
NS_RB="RB"; NS_RA="RA"; NS_RC="RC"; NS_RD="RD"; NS_RE="RE"
NS_SW57A="SW57A"; NS_SW57B="SW57B"; NS_SW57C="SW57C"
NS_H57A="H57A"; NS_H57B="H57B"; NS_H57C="H57C"
NS_GW="GW"   # 模拟互联网出口路由器 192.168.99.1

# ---- 网桥 ----
BR_56A="br_SW56A"; BR_57A="br_SW57A"; BR_57B="br_SW57B"; BR_57C="br_SW57C"

# ---- VETH（主机/路由器侧 : 交换机侧）----
V_H56A="ve-H56A";      V_SW56A_H56A="ve-SW56A-H56A"
V_RB_56A="ve-RB-SW56A";V_SW56A_RB="ve-SW56A-RB"
V_RB_RA="ve-RB-RA";    V_RA_RB="ve-RA-RB"
V_RC_RA="ve-RC-RA";    V_RA_RC="ve-RA-RC"
V_RD_RA="ve-RD-RA";    V_RA_RD="ve-RA-RD"
V_RA_GW="ve-RA-GW";    V_GW_RA="ve-GW-RA"
V_RC_57A="ve-RC-SW57A";V_SW57A_RC="ve-SW57A-RC"
V_RE_57A="ve-RE-SW57A";V_SW57A_RE="ve-SW57A-RE"
V_H57A="ve-H57A";      V_SW57A_H57A="ve-SW57A-H57A"
V_RE_57B="ve-RE-SW57B";V_SW57B_RE="ve-SW57B-RE"
V_H57B="ve-H57B";      V_SW57B_H57B="ve-SW57B-H57B"
V_RD_57C="ve-RD-SW57C";V_SW57C_RD="ve-SW57C-RD"
V_RE_57C="ve-RE-SW57C";V_SW57C_RE="ve-SW57C-RE"
V_H57C="ve-H57C";      V_SW57C_H57C="ve-SW57C-H57C"

# ---- IP 规划（指导书固定地址）----
IP_H56A="192.168.56.126/25"
IP_RB_56A="192.168.56.1/25"
IP_RB_RA="192.168.56.245/30"; IP_RA_RB="192.168.56.246/30"   # RB-RA 192.168.56.244/30
IP_RC_RA="192.168.56.249/30"; IP_RA_RC="192.168.56.250/30"   # RC-RA 192.168.56.248/30
IP_RD_RA="192.168.56.253/30"; IP_RA_RD="192.168.56.254/30"   # RD-RA 192.168.56.252/30
IP_RA_GW="192.168.99.100/24"; IP_GW="192.168.99.1/24"        # 互联网出口 192.168.99.0/24
IP_RC_57A="192.168.57.1/25"
IP_RE_57A="192.168.57.125/25"
IP_H57A="192.168.57.126/25"
IP_RE_57B="192.168.57.129/26"
IP_H57B="192.168.57.190/26"
IP_RD_57C="192.168.57.193/26"
IP_RE_57C="192.168.57.253/26"
IP_H57C="192.168.57.254/26"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root/sudo 执行" >&2; exit 1; }

ns_exists() { ip netns list | grep -qw "$1"; }

offload_off() {
    # 失败留痕（veth 的 rx off 可能被内核拒绝，属已知限制），不静默吞错
    if ! ip netns exec "$1" ethtool -K "$2" rx off tx off gso off tso off gro off 2>/dev/null; then
        echo "[警告] $1.$2 offload 关闭失败（检查 ethtool 是否安装）" >&2
    fi
}

do_create() {
    # 幂等性保护: 若拓扑已存在，先销毁旧拓扑再重建
    if ns_exists "$NS_H56A" || ns_exists "$NS_SW56A" || ns_exists "$NS_RB" || ns_exists "$NS_RA" \
       || ns_exists "$NS_RC" || ns_exists "$NS_RD" || ns_exists "$NS_RE" || ns_exists "$NS_SW57A" \
       || ns_exists "$NS_SW57B" || ns_exists "$NS_SW57C" || ns_exists "$NS_H57A" || ns_exists "$NS_H57B" \
       || ns_exists "$NS_H57C" || ns_exists "$NS_GW"; then
        echo "==> 检测到已有同名命名空间，先销毁旧拓扑"
        do_destroy
    fi
    # 创建中途失败时回滚，避免留下半成品状态
    trap 'echo "[错误] 创建失败，回滚已创建的资源" >&2; do_destroy' ERR

    echo "==> 创建 14 个网络命名空间"
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RC" "$NS_RD" "$NS_RE" \
              "$NS_SW57A" "$NS_SW57B" "$NS_SW57C" "$NS_H57A" "$NS_H57B" "$NS_H57C" "$NS_GW"; do
        ip netns add "$ns"
        ip netns exec "$ns" ip link set lo up
    done

    echo "==> 创建 4 个网桥（交换机）"
    ip netns exec "$NS_SW56A" ip link add "$BR_56A" type bridge
    ip netns exec "$NS_SW57A" ip link add "$BR_57A" type bridge
    ip netns exec "$NS_SW57B" ip link add "$BR_57B" type bridge
    ip netns exec "$NS_SW57C" ip link add "$BR_57C" type bridge
    for spec in "$NS_SW56A $BR_56A" "$NS_SW57A $BR_57A" "$NS_SW57B $BR_57B" "$NS_SW57C $BR_57C"; do
        ip netns exec "${spec%% *}" ip link set "${spec#* }" up
    done

    echo "==> 创建 14 对 VETH 并迁移"
    ip link add "$V_H56A"     type veth peer name "$V_SW56A_H56A"
    ip link add "$V_RB_56A"   type veth peer name "$V_SW56A_RB"
    ip link add "$V_RB_RA"    type veth peer name "$V_RA_RB"
    ip link add "$V_RC_RA"    type veth peer name "$V_RA_RC"
    ip link add "$V_RD_RA"    type veth peer name "$V_RA_RD"
    ip link add "$V_RA_GW"    type veth peer name "$V_GW_RA"
    ip link add "$V_RC_57A"   type veth peer name "$V_SW57A_RC"
    ip link add "$V_RE_57A"   type veth peer name "$V_SW57A_RE"
    ip link add "$V_H57A"     type veth peer name "$V_SW57A_H57A"
    ip link add "$V_RE_57B"   type veth peer name "$V_SW57B_RE"
    ip link add "$V_H57B"     type veth peer name "$V_SW57B_H57B"
    ip link add "$V_RD_57C"   type veth peer name "$V_SW57C_RD"
    ip link add "$V_RE_57C"   type veth peer name "$V_SW57C_RE"
    ip link add "$V_H57C"     type veth peer name "$V_SW57C_H57C"

    ip link set "$V_H56A"       netns "$NS_H56A";  ip link set "$V_SW56A_H56A" netns "$NS_SW56A"
    ip link set "$V_RB_56A"     netns "$NS_RB";    ip link set "$V_SW56A_RB"   netns "$NS_SW56A"
    ip link set "$V_RB_RA"      netns "$NS_RB";    ip link set "$V_RA_RB"      netns "$NS_RA"
    ip link set "$V_RC_RA"      netns "$NS_RC";    ip link set "$V_RA_RC"      netns "$NS_RA"
    ip link set "$V_RD_RA"      netns "$NS_RD";    ip link set "$V_RA_RD"      netns "$NS_RA"
    ip link set "$V_RA_GW"      netns "$NS_RA";    ip link set "$V_GW_RA"      netns "$NS_GW"
    ip link set "$V_RC_57A"     netns "$NS_RC";    ip link set "$V_SW57A_RC"   netns "$NS_SW57A"
    ip link set "$V_RE_57A"     netns "$NS_RE";    ip link set "$V_SW57A_RE"   netns "$NS_SW57A"
    ip link set "$V_H57A"       netns "$NS_H57A";  ip link set "$V_SW57A_H57A" netns "$NS_SW57A"
    ip link set "$V_RE_57B"     netns "$NS_RE";    ip link set "$V_SW57B_RE"   netns "$NS_SW57B"
    ip link set "$V_H57B"       netns "$NS_H57B";  ip link set "$V_SW57B_H57B" netns "$NS_SW57B"
    ip link set "$V_RD_57C"     netns "$NS_RD";    ip link set "$V_SW57C_RD"   netns "$NS_SW57C"
    ip link set "$V_RE_57C"     netns "$NS_RE";    ip link set "$V_SW57C_RE"   netns "$NS_SW57C"
    ip link set "$V_H57C"       netns "$NS_H57C";  ip link set "$V_SW57C_H57C" netns "$NS_SW57C"

    echo "==> 交换机侧 VETH 绑定网桥"
    ip netns exec "$NS_SW56A" ip link set "$V_SW56A_H56A" master "$BR_56A"
    ip netns exec "$NS_SW56A" ip link set "$V_SW56A_RB"   master "$BR_56A"
    ip netns exec "$NS_SW57A" ip link set "$V_SW57A_RC"   master "$BR_57A"
    ip netns exec "$NS_SW57A" ip link set "$V_SW57A_RE"   master "$BR_57A"
    ip netns exec "$NS_SW57A" ip link set "$V_SW57A_H57A" master "$BR_57A"
    ip netns exec "$NS_SW57B" ip link set "$V_SW57B_RE"   master "$BR_57B"
    ip netns exec "$NS_SW57B" ip link set "$V_SW57B_H57B" master "$BR_57B"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_RD"   master "$BR_57C"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_RE"   master "$BR_57C"
    ip netns exec "$NS_SW57C" ip link set "$V_SW57C_H57C" master "$BR_57C"

    echo "==> 配置 IP 并启用全部接口"
    ip netns exec "$NS_H56A" ip addr add "$IP_H56A"   dev "$V_H56A"
    ip netns exec "$NS_RB"   ip addr add "$IP_RB_56A" dev "$V_RB_56A"
    ip netns exec "$NS_RB"   ip addr add "$IP_RB_RA"  dev "$V_RB_RA"
    ip netns exec "$NS_RA"   ip addr add "$IP_RA_RB"  dev "$V_RA_RB"
    ip netns exec "$NS_RC"   ip addr add "$IP_RC_RA"  dev "$V_RC_RA"
    ip netns exec "$NS_RA"   ip addr add "$IP_RA_RC"  dev "$V_RA_RC"
    ip netns exec "$NS_RD"   ip addr add "$IP_RD_RA"  dev "$V_RD_RA"
    ip netns exec "$NS_RA"   ip addr add "$IP_RA_RD"  dev "$V_RA_RD"
    ip netns exec "$NS_RA"   ip addr add "$IP_RA_GW"  dev "$V_RA_GW"
    ip netns exec "$NS_GW"   ip addr add "$IP_GW"     dev "$V_GW_RA"
    ip netns exec "$NS_RC"   ip addr add "$IP_RC_57A" dev "$V_RC_57A"
    ip netns exec "$NS_RE"   ip addr add "$IP_RE_57A" dev "$V_RE_57A"
    ip netns exec "$NS_H57A" ip addr add "$IP_H57A"   dev "$V_H57A"
    ip netns exec "$NS_RE"   ip addr add "$IP_RE_57B" dev "$V_RE_57B"
    ip netns exec "$NS_H57B" ip addr add "$IP_H57B"   dev "$V_H57B"
    ip netns exec "$NS_RD"   ip addr add "$IP_RD_57C" dev "$V_RD_57C"
    ip netns exec "$NS_RE"   ip addr add "$IP_RE_57C" dev "$V_RE_57C"
    ip netns exec "$NS_H57C" ip addr add "$IP_H57C"   dev "$V_H57C"

    for spec in \
        "$NS_H56A $V_H56A" "$NS_SW56A $V_SW56A_H56A" "$NS_SW56A $V_SW56A_RB" \
        "$NS_RB $V_RB_56A" "$NS_RB $V_RB_RA" "$NS_RA $V_RA_RB" "$NS_RC $V_RC_RA" \
        "$NS_RA $V_RA_RC" "$NS_RD $V_RD_RA" "$NS_RA $V_RA_RD" "$NS_RA $V_RA_GW" \
        "$NS_GW $V_GW_RA" "$NS_RC $V_RC_57A" "$NS_SW57A $V_SW57A_RC" \
        "$NS_RE $V_RE_57A" "$NS_SW57A $V_SW57A_RE" "$NS_SW57A $V_SW57A_H57A" \
        "$NS_H57A $V_H57A" "$NS_RE $V_RE_57B" "$NS_SW57B $V_SW57B_RE" \
        "$NS_SW57B $V_SW57B_H57B" "$NS_H57B $V_H57B" "$NS_RD $V_RD_57C" \
        "$NS_SW57C $V_SW57C_RD" "$NS_RE $V_RE_57C" "$NS_SW57C $V_SW57C_RE" \
        "$NS_SW57C $V_SW57C_H57C" "$NS_H57C $V_H57C"; do
        ip netns exec "${spec%% *}" ip link set "${spec#* }" up
    done

    echo "==> 路由器开启转发"
    for ns in "$NS_RB" "$NS_RA" "$NS_RC" "$NS_RD" "$NS_RE" "$NS_GW"; do
        ip netns exec "$ns" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    done

    echo "==> 配置静态路由与默认路由"
    # 主机默认网关
    ip netns exec "$NS_H56A" ip route add default via 192.168.56.1
    ip netns exec "$NS_H57A" ip route add default via 192.168.57.1
    ip netns exec "$NS_H57B" ip route add default via 192.168.57.129
    ip netns exec "$NS_H57C" ip route add default via 192.168.57.193
    # RB: 57 各网段与 99 网段均经 RA
    ip netns exec "$NS_RB" ip route add 192.168.57.0/25   via 192.168.56.246
    ip netns exec "$NS_RB" ip route add 192.168.57.128/26 via 192.168.56.246
    ip netns exec "$NS_RB" ip route add 192.168.57.192/26 via 192.168.56.246
    ip netns exec "$NS_RB" ip route add 192.168.99.0/24   via 192.168.56.246
    # RC: 56/99 网段经 RA（下一跳 = RA 侧地址 .250，不能写本机地址 .249）；
    #     57B/57C 网段经 RE（同网段直连 RE，下一跳 = RE 侧地址 .125）
    ip netns exec "$NS_RC" ip route add 192.168.56.0/25    via 192.168.56.250
    ip netns exec "$NS_RC" ip route add 192.168.99.0/24    via 192.168.56.250
    ip netns exec "$NS_RC" ip route add 192.168.57.128/26  via 192.168.57.125
    ip netns exec "$NS_RC" ip route add 192.168.57.192/26  via 192.168.57.125
    # RD: 56/99 网段经 RA（下一跳 = RA 侧地址 .254，不能写本机地址 .253）；
    #     57A/57B 网段经 RE（同网段直连 RE，下一跳 = RE 侧地址 .253）
    ip netns exec "$NS_RD" ip route add 192.168.56.0/25    via 192.168.56.254
    ip netns exec "$NS_RD" ip route add 192.168.99.0/24    via 192.168.56.254
    ip netns exec "$NS_RD" ip route add 192.168.57.0/25    via 192.168.57.253
    ip netns exec "$NS_RD" ip route add 192.168.57.128/26  via 192.168.57.253
    # RE: 56/99 网段经 RC
    ip netns exec "$NS_RE" ip route add 192.168.56.0/25    via 192.168.57.1
    ip netns exec "$NS_RE" ip route add 192.168.99.0/24    via 192.168.57.1
    # RA: 57A 网段经 RC（下一跳 = RC 侧地址 .249）；
    #     57B 网段经 RC（与 step8 宣称的 RB->RA->RC->RE 路径一致，RC 再经 RE 转发）；
    #     57C 网段经 RD（下一跳 = RD 侧地址 .253）；默认路由指向互联网出口
    ip netns exec "$NS_RA" ip route add 192.168.57.0/25    via 192.168.56.249
    ip netns exec "$NS_RA" ip route add 192.168.57.128/26  via 192.168.56.249
    ip netns exec "$NS_RA" ip route add 192.168.57.192/26  via 192.168.56.253
    ip netns exec "$NS_RA" ip route add default via 192.168.99.1

    echo "==> 关闭全部主机/路由器 VETH 的 offload"
    offload_off "$NS_H56A" "$V_H56A";  offload_off "$NS_H57A" "$V_H57A"
    offload_off "$NS_H57B" "$V_H57B";  offload_off "$NS_H57C" "$V_H57C"
    offload_off "$NS_RB" "$V_RB_56A";  offload_off "$NS_RB" "$V_RB_RA"
    offload_off "$NS_RA" "$V_RA_RB";   offload_off "$NS_RA" "$V_RA_RC"
    offload_off "$NS_RA" "$V_RA_RD";   offload_off "$NS_RA" "$V_RA_GW"
    offload_off "$NS_RC" "$V_RC_RA";   offload_off "$NS_RC" "$V_RC_57A"
    offload_off "$NS_RD" "$V_RD_RA";   offload_off "$NS_RD" "$V_RD_57C"
    offload_off "$NS_RE" "$V_RE_57A";  offload_off "$NS_RE" "$V_RE_57B"
    offload_off "$NS_RE" "$V_RE_57C"

    echo "==> 拓扑创建完成"
    trap - ERR
}

do_verify() {
    verify_fail=0
    echo "==> 命名空间列表"; ip netns list
    echo "==> 网桥绑定"
    # bridge link show 不支持裸设备名过滤（参数被静默忽略），改用 ip link show master
    for spec in "$NS_SW56A $BR_56A" "$NS_SW57A $BR_57A" "$NS_SW57B $BR_57B" "$NS_SW57C $BR_57C"; do
        echo "--- ${spec#* } ---"
        ip netns exec "${spec%% *}" ip link show master "${spec#* }"
    done
    echo "==> 各节点地址与路由"
    for ns in "$NS_H56A" "$NS_RB" "$NS_RA" "$NS_RC" "$NS_RD" "$NS_RE" "$NS_H57A" "$NS_H57B" "$NS_H57C" "$NS_GW"; do
        echo "--- $ns ---"
        ip netns exec "$ns" ip -4 -br addr
        ip netns exec "$ns" ip route
    done
    echo "==> 可达性测试（H56A -> H57A / H57B / H57C）"
    for dst in 192.168.57.126 192.168.57.190 192.168.57.254; do
        if ip netns exec "$NS_H56A" ping -c 2 "$dst"; then
            echo "    $dst 可达 ✓"
        else
            echo "    $dst 不通 ✗（检查静态路由/下一跳配置）" >&2
            verify_fail=1
        fi
    done
    [ "$verify_fail" -eq 0 ] && echo "==> 验证全部通过 ✓" || { echo "==> 验证存在失败项 ✗" >&2; exit 1; }
}

do_destroy() {
    echo "==> 终止命名空间内的残留进程（ncat/tshark），再删除命名空间"
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RC" "$NS_RD" "$NS_RE" \
              "$NS_SW57A" "$NS_SW57B" "$NS_SW57C" "$NS_H57A" "$NS_H57B" "$NS_H57C" "$NS_GW"; do
        if ns_exists "$ns"; then
            pids=$(ip netns pids "$ns" 2>/dev/null || true)
            [ -n "$pids" ] && kill $pids 2>/dev/null || true
        fi
    done
    sleep 1
    for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RC" "$NS_RD" "$NS_RE" \
              "$NS_SW57A" "$NS_SW57B" "$NS_SW57C" "$NS_H57A" "$NS_H57B" "$NS_H57C" "$NS_GW"; do
        ip netns del "$ns" 2>/dev/null || true
    done
    for v in "$V_H56A" "$V_RB_56A" "$V_RB_RA" "$V_RC_RA" "$V_RD_RA" "$V_RA_GW" \
             "$V_RC_57A" "$V_RE_57A" "$V_H57A" "$V_RE_57B" "$V_H57B" "$V_RD_57C" \
             "$V_RE_57C" "$V_H57C"; do
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
#   create: 各步骤无报错完成。
#   verify:
#     1) ip netns list 列出 14 个命名空间（含模拟出口的 GW）；
#     2) 4 个网桥各绑定 2~3 个 VETH 接口；
#     3) 各节点地址与规划一致，路由表含静态路由/默认路由；
#     4) 三次 ping 各输出 "2 packets transmitted, 2 received, 0% loss"：
#        H56A->H57A 路径 RB-RA-RC，H56A->H57B 路径 RB-RA-RC-RE，
#        H56A->H57C 路径 RB-RA-RD，跨多路由器全部可达。
#   destroy: 全部清理干净。
# ------------------------------------------------------------
