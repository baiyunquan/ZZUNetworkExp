#!/usr/bin/env bash
# =============================================================
# 实验1 步骤3：IPv4 配置、连通性测试及数据包抓取
# 对应指导书《实验1》步骤3
# 用法: sudo ./step3_ipv4_test.sh [pcap保存目录，默认 /tmp]
# 说明: 指导书使用 GUI Wireshark 抓包；本脚本默认用 tshark 命令行
#       完成等价抓包（保存 pcap 供 Wireshark 分析），如需 GUI 抓包
#       请手动执行: ip netns exec HA wireshark &
# =============================================================
set -euo pipefail

NS_HA="HA"; NS_HB="HB"
IF_HA="ve-ha-swa"; IF_HB="ve-hb-swa"
IP_HA="192.168.50.1/24"; IP_HB="192.168.50.2/24"
PCAP_DIR="${1:-/tmp}"
PCAP="$PCAP_DIR/exp1_ipv4.pcap"

echo "==> (1) 为两台主机配置 IPv4 地址并启用接口"
# 幂等: 地址已存在则跳过（ip addr add 会报 File exists 直接中止脚本）
if ! ip netns exec "$NS_HA" ip addr show dev "$IF_HA" | grep -qw "${IP_HA%/*}"; then
    ip netns exec "$NS_HA" ip addr add "$IP_HA" dev "$IF_HA"
fi
if ! ip netns exec "$NS_HB" ip addr show dev "$IF_HB" | grep -qw "${IP_HB%/*}"; then
    ip netns exec "$NS_HB" ip addr add "$IP_HB" dev "$IF_HB"
fi
ip netns exec "$NS_HA" ip link set "$IF_HA" up
ip netns exec "$NS_HB" ip link set "$IF_HB" up
ip netns exec "$NS_HA" ip addr show "$IF_HA"
ip netns exec "$NS_HB" ip addr show "$IF_HB"

if command -v tshark >/dev/null 2>&1; then
    echo "==> (2) 启动抓包（tshark 后台抓取 $IF_HA，等价于 GUI Wireshark）"
    # -a duration: 自动定时停止，避免依赖 sleep 时序导致 pcap 截断
    ip netns exec "$NS_HA" tshark -i "$IF_HA" -a duration:8 -w "$PCAP" &
    TSHARK_PID=$!
    sleep 1
else
    echo "==> (2) [跳过] 未安装 tshark。请手动执行: ip netns exec $NS_HA wireshark &"
    TSHARK_PID=""
fi

echo "==> (3) 执行 IPv4 连通性测试（HA -> HB）"
ip netns exec "$NS_HA" ping -c 2 "${IP_HB%/*}"

if [ -n "$TSHARK_PID" ]; then
    echo "==> (4) 停止抓包，保存为 $PCAP"
    sleep 1
    kill "$TSHARK_PID" 2>/dev/null || true
    wait "$TSHARK_PID" 2>/dev/null || true
    ls -l "$PCAP"
fi

# ------------------------------------------------------------
# 预期实验现象:
#   (1) ip addr show 显示 ve-ha-swa 的 inet 为 192.168.50.1/24、
#       ve-hb-swa 的 inet 为 192.168.50.2/24，接口状态 UP；
#   (3) ping 输出:
#         PING 192.168.50.2 (192.168.50.2) 56(84) bytes of data.
#         64 bytes from 192.168.50.2: icmp_seq=1 ttl=64 time=x.xx ms
#         64 bytes from 192.168.50.2: icmp_seq=2 ttl=64 time=x.xx ms
#         --- 192.168.50.2 ping statistics ---
#         2 packets transmitted, 2 received, 0% packet loss
#       即"已发送 2 个包，已接收 2 个包"，说明 IPv4 连通正常；
#   (4) pcap 文件生成（约几 KB），用 Wireshark 打开可见:
#       ARP 请求/应答（首次通信前主机互相询问 MAC）+ ICMP Echo 请求/应答各 2 对，
#       可据此分析同一局域网内 IPv4 通信的完整过程。
#   若 ping 不通: 检查接口是否 up、IP 是否同网段、VETH 是否已绑定网桥。
# ------------------------------------------------------------
