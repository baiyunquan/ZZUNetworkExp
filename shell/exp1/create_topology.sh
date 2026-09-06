#!/usr/bin/env bash
# =============================================================
# 实验1 步骤5（要求实现的脚本）：一键创建/验证/销毁实验1网络拓扑
# 拓扑: 主机HA --交换机SWA(网桥br-swa)-- 主机HB，IPv4/IPv6 双协议栈
# 对应指导书《实验1》步骤5 "自动化脚本编写、部署与实验"
#
# 用法:
#   sudo ./create_topology.sh create    # 一键创建拓扑并完成双栈配置
#   sudo ./create_topology.sh verify    # 验证拓扑与配置（对应步骤5(3)）
#   sudo ./create_topology.sh destroy   # 销毁拓扑，释放资源
# =============================================================
set -euo pipefail

NS_HA="HA"; NS_HB="HB"; NS_SWA="SWA"
BR="br-swa"
VETH_HA="ve-ha-swa"; VETH_HA_PEER="ve-swa-ha"
VETH_HB="ve-hb-swa"; VETH_HB_PEER="ve-swa-hb"
IP_HA="192.168.50.1/24"; IP_HB="192.168.50.2/24"
IP6_HA="fd00::1:1/64";   IP6_HB="fd00::1:2/64"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root/sudo 执行" >&2; exit 1; }

ns_exists() { ip netns list | grep -qw "$1"; }

do_create() {
    # 幂等性保护: 若拓扑已存在，先销毁旧拓扑再重建
    if ns_exists "$NS_HA" || ns_exists "$NS_HB" || ns_exists "$NS_SWA"; then
        echo "==> 检测到已有同名命名空间，先销毁旧拓扑"
        do_destroy
    fi
    # 创建中途失败时回滚，避免留下半成品状态
    trap 'echo "[错误] 创建失败，回滚已创建的资源" >&2; do_destroy' ERR

    echo "==> 创建网络命名空间"
    ip netns add "$NS_HA"
    ip netns add "$NS_HB"
    ip netns add "$NS_SWA"

    echo "==> 在 SWA 内创建并启用网桥 $BR"
    ip netns exec "$NS_SWA" ip link add "$BR" type bridge
    ip netns exec "$NS_SWA" ip link set "$BR" up

    echo "==> 创建 VETH 对并迁移到命名空间"
    ip link add "$VETH_HA" type veth peer name "$VETH_HA_PEER"
    ip link add "$VETH_HB" type veth peer name "$VETH_HB_PEER"
    ip link set "$VETH_HA" netns "$NS_HA"
    ip link set "$VETH_HA_PEER" netns "$NS_SWA"
    ip link set "$VETH_HB" netns "$NS_HB"
    ip link set "$VETH_HB_PEER" netns "$NS_SWA"

    echo "==> 交换机侧 VETH 绑定网桥并启用"
    ip netns exec "$NS_SWA" ip link set "$VETH_HA_PEER" master "$BR"
    ip netns exec "$NS_SWA" ip link set "$VETH_HB_PEER" master "$BR"
    ip netns exec "$NS_SWA" ip link set "$VETH_HA_PEER" up
    ip netns exec "$NS_SWA" ip link set "$VETH_HB_PEER" up

    echo "==> 配置主机 IPv4/IPv6 双协议栈并启用接口"
    ip netns exec "$NS_HA" ip addr add "$IP_HA"  dev "$VETH_HA"
    ip netns exec "$NS_HB" ip addr add "$IP_HB"  dev "$VETH_HB"
    ip netns exec "$NS_HA" ip addr add "$IP6_HA" dev "$VETH_HA"
    ip netns exec "$NS_HB" ip addr add "$IP6_HB" dev "$VETH_HB"
    ip netns exec "$NS_HA" ip link set "$VETH_HA" up
    ip netns exec "$NS_HB" ip link set "$VETH_HB" up

    echo "==> 拓扑创建完成，执行 verify 子命令可验证"
    trap - ERR
}

do_verify() {
    echo "==> 验证命名空间"
    ip netns list
    for ns in "$NS_HA" "$NS_HB" "$NS_SWA"; do
        echo "==> $ns 内的网络接口"
        ip netns exec "$ns" ip link show
    done
    echo "==> 交换机网桥绑定状态"
    ip netns exec "$NS_SWA" bridge link show dev "$BR"
    for ns in "$NS_HA" "$NS_HB"; do
        echo "==> $ns 的 IPv4/IPv6 地址配置"
        ip netns exec "$ns" ip addr
    done
    echo "==> 连通性测试"
    # 注意: 不能写成 `ping && echo ✓`，set -e 下 ping 失败会静默中断脚本
    if ip netns exec "$NS_HA" ping -c 2 "${IP_HB%/*}"; then
        echo "IPv4 连通 ✓"
    else
        echo "IPv4 不通 ✗（检查接口 up / IP 配置 / 网桥绑定）" >&2
    fi
    if ip netns exec "$NS_HA" ping -c 2 "${IP6_HB%/*}"; then
        echo "IPv6 连通 ✓"
    else
        echo "IPv6 不通 ✗（检查 IPv6 地址前缀 / 接口 up）" >&2
    fi
}

do_destroy() {
    echo "==> 终止命名空间内的残留进程（如 tshark），再删除命名空间"
    for ns in "$NS_HA" "$NS_HB" "$NS_SWA"; do
        if ns_exists "$ns"; then
            # 命名空间被存活进程持有时 netns del 无法真正销毁，先 kill
            pids=$(ip netns pids "$ns" 2>/dev/null || true)
            [ -n "$pids" ] && kill $pids 2>/dev/null || true
        fi
    done
    sleep 1
    echo "==> 删除命名空间（其内 veth/bridge 随之自动销毁）"
    ip netns del "$NS_HA"  2>/dev/null || true
    ip netns del "$NS_HB"  2>/dev/null || true
    ip netns del "$NS_SWA" 2>/dev/null || true
    # 兜底清理可能残留在主空间的 VETH
    ip link del "$VETH_HA" 2>/dev/null || true
    ip link del "$VETH_HB" 2>/dev/null || true
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
#     依次输出各步骤提示，无报错结束；ip netns list 出现 HA/HB/SWA。
#   verify:
#     1) ip netns list 显示 HA、HB、SWA 三个命名空间；
#     2) HA 内可见 ve-ha-swa，HB 内可见 ve-hb-swa，
#        SWA 内可见 br-swa、ve-swa-ha、ve-swa-hb，且状态 UP；
#     3) bridge link show dev br-swa 列出两个已绑定的 VETH 接口；
#     4) HA/HB 的 ip addr 同时显示 IPv4（192.168.50.x/24）与
#        IPv6（fd00::1:x/64 + fe80 链路本地）地址；
#     5) 两次 ping 各输出 "2 packets transmitted, 2 received, 0% packet loss"，
#        打印 "IPv4 连通 ✓" 与 "IPv6 连通 ✓"。
#   destroy:
#     输出清理提示后，ip netns list 不再包含 HA/HB/SWA，
#     主空间 ip link show 无 ve- 开头接口，系统恢复初始状态。
# ------------------------------------------------------------
