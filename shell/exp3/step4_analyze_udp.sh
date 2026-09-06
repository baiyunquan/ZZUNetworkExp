#!/usr/bin/env bash
# =============================================================
# 实验3 步骤6：UDP 数据包分析（等价 Wireshark 过滤与分析）
# 对应指导书《实验3》步骤6
# 用法: ./step4_analyze_udp.sh [pcap，默认 /tmp/exp3_udp.pcap]
# =============================================================
set -euo pipefail
PCAP="${1:-/tmp/exp3_udp.pcap}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step3_udp_comm.sh" >&2; exit 1; }

echo "==> (1) 筛选 UDP 报文（等价显示过滤器 udp）"
tshark -r "$PCAP" -Y "udp" 2>/dev/null | head -10

echo ""
echo "==> (2) 提取 UDP 首部字段（源端口/目的端口/长度/校验和）"
tshark -r "$PCAP" -Y "udp" -T fields \
    -e frame.number -e ip.src -e ip.dst \
    -e udp.srcport -e udp.dstport -e udp.length -e udp.checksum \
    2>/dev/null | head -10

echo ""
echo "==> (3) UDP 首部结构解读（对照 RFC 768，共 8 字节）"
cat <<'EOF'
    0      7 8     15 16    23 24    31
   +---------+---------+---------+---------+
   |  源端口   |  目的端口 |                    |
   +---------+---------+  长度   +  校验和   +
   |           数据（可变长）               |
   +---------------------------------------+
   - 源端口(2B)/目的端口(2B): 标识发送/接收应用进程，本实验服务端=4499
   - 长度(2B): 首部+数据的总字节数（最小值 8，即无数据）
   - 校验和(2B): 覆盖伪首部+首部+数据，用于接收方差错检测（可选但IPv4下常算）
   对比 TCP: 无序号、无确认、无握手 —— 体现无连接、不可靠、尽最大努力交付
EOF

echo ""
echo "==> (4) 校验和验证（checksum.status: good 表示校验通过）"
tshark -r "$PCAP" -Y "udp" -T fields -e udp.checksum.status 2>/dev/null | sort | uniq -c

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 列出抓到的 UDP 报文（去往/来自 192.168.57.254:4499），
#       无 TCP 握手报文；
#   (2) 字段表显示:
#       客户端->服务端: udp.srcport=临时端口(如 33152), udp.dstport=4499,
#                       udp.length=8+数据长度, udp.checksum=0x????;
#       服务端->客户端: udp.srcport=4499, udp.dstport=客户端临时端口;
#   (3) 输出 UDP 首部结构图与字段说明；
#   (4) checksum.status 统计为 good（因已关闭 offload，校验和由 CPU
#       计算，Wireshark 验证通过；若 offload 未关会显示 bad/unsupported）。
#   分析结论: UDP 首部仅 8 字节、无连接建立/释放报文、发送后不确认
#   —— 验证了 UDP 无连接、不可靠、面向报文的传输特性。
# ------------------------------------------------------------
