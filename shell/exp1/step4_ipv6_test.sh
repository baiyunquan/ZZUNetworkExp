#!/usr/bin/env bash
# =============================================================
# 实验1 步骤4：IPv6 配置、连通性测试及数据包抓取
# 对应指导书《实验1》步骤4
# 用法: sudo ./step4_ipv6_test.sh [pcap保存目录，默认 /tmp]
# 前置: 已完成步骤2/3（拓扑已建、接口已 up）
# =============================================================
set -euo pipefail

NS_HA="HA"; NS_HB="HB"
IF_HA="ve-ha-swa"; IF_HB="ve-hb-swa"
IP6_HA="fd00::1:1/64"; IP6_HB="fd00::1:2/64"
PCAP_DIR="${1:-/tmp}"
PCAP="$PCAP_DIR/exp1_ipv6.pcap"

echo "==> (1) 为两台主机配置 IPv6 ULA 地址"
# 幂等: 地址已存在则跳过；同时确保接口 up（不依赖步骤3是否已执行）
if ! ip netns exec "$NS_HA" ip -6 addr show dev "$IF_HA" | grep -qw "${IP6_HA%/*}"; then
    ip netns exec "$NS_HA" ip addr add "$IP6_HA" dev "$IF_HA"
fi
if ! ip netns exec "$NS_HB" ip -6 addr show dev "$IF_HB" | grep -qw "${IP6_HB%/*}"; then
    ip netns exec "$NS_HB" ip addr add "$IP6_HB" dev "$IF_HB"
fi
ip netns exec "$NS_HA" ip link set "$IF_HA" up
ip netns exec "$NS_HB" ip link set "$IF_HB" up
ip netns exec "$NS_HA" ip -6 addr show "$IF_HA"
ip netns exec "$NS_HB" ip -6 addr show "$IF_HB"

if command -v tshark >/dev/null 2>&1; then
    echo "==> (2) 启动抓包（tshark 后台抓取 $IF_HA）"
    # -a duration: 自动定时停止，避免依赖 sleep 时序导致 pcap 截断
    ip netns exec "$NS_HA" tshark -i "$IF_HA" -a duration:8 -w "$PCAP" &
    TSHARK_PID=$!
    sleep 1
else
    echo "==> (2) [跳过] 未安装 tshark。请手动执行: ip netns exec $NS_HA wireshark &"
    TSHARK_PID=""
fi

echo "==> (3) 执行 IPv6 连通性测试（HA -> HB）"
ip netns exec "$NS_HA" ping -c 2 "${IP6_HB%/*}"

if [ -n "$TSHARK_PID" ]; then
    echo "==> (4) 停止抓包，保存为 $PCAP"
    sleep 1
    kill "$TSHARK_PID" 2>/dev/null || true
    wait "$TSHARK_PID" 2>/dev/null || true
    ls -l "$PCAP"
fi

# ------------------------------------------------------------
# 预期实验现象:
#   (1) ip -6 addr show 显示 ve-ha-swa 含 inet6 fd00::1:1/64（scope global）、
#       ve-hb-swa 含 inet6 fd00::1:2/64，同时各自自动生成
#       fe80::/10 链路本地地址（scope link）；
#   (3) ping 输出:
#         PING fd00::1:2 (fd00::1:2) 56 data bytes
#         64 bytes from fd00::1:2: icmp_seq=1 ttl=64 time=x.xx ms
#         64 bytes from fd00::1:2: icmp_seq=2 ttl=64 time=x.xx ms
#         --- fd00::1:2 ping statistics ---
#         2 packets transmitted, 2 received, 0% packet loss
#       即"已发送 2 个包，已接收 2 个包"，说明 IPv6 连通正常；
#   (4) pcap 用 Wireshark 打开可见:
#       ICMPv6 组播侦听/邻居请求（NDP，替代 IPv4 的 ARP）+ ICMPv6 Echo 请求/应答各 2 对，
#       可对比 IPv4 与 IPv6 地址解析机制的差异。
#   若 ping 不通: 检查 IPv6 地址前缀是否一致（fd00::/64）、接口是否 up。
# ------------------------------------------------------------
