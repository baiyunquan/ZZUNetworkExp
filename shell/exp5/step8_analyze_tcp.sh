#!/usr/bin/env bash
# =============================================================
# 实验5 步骤8：TCP 重传机制分析（超时重传/快重传/部分ACK）
# 对应指导书《实验5》步骤8
# 用法: ./step8_analyze_tcp.sh [pcap，默认 /tmp/exp5_tcp.pcap]
# =============================================================
set -euo pipefail
PCAP="${1:-/tmp/exp5_tcp.pcap}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step7_tcp_transfer.sh" >&2; exit 1; }

echo "==> (1) 重传报文总览（tshark 专家分析字段）"
echo "    --- 超时重传（RTO 超时触发，重传全部未确认段）---"
tshark -r "$PCAP" -Y "tcp.analysis.retransmission && !tcp.analysis.fast_retransmission" -T fields \
    -e frame.number -e ip.src -e tcp.seq -e tcp.ack -e tcp.len 2>/dev/null | head -10

echo "    --- 快重传（收到 3 个重复 ACK 后立即重传，无需等待 RTO）---"
tshark -r "$PCAP" -Y "tcp.analysis.fast_retransmission" -T fields \
    -e frame.number -e ip.src -e tcp.seq -e tcp.ack -e tcp.len 2>/dev/null | head -10

echo ""
echo "==> (2) 重传统计"
RTO=$(tshark -r "$PCAP" -Y "tcp.analysis.retransmission && !tcp.analysis.fast_retransmission" 2>/dev/null | wc -l)
FAST=$(tshark -r "$PCAP" -Y "tcp.analysis.fast_retransmission" 2>/dev/null | wc -l)
DUPACK=$(tshark -r "$PCAP" -Y "tcp.analysis.duplicate_ack" 2>/dev/null | wc -l)
SPUR=$(tshark -r "$PCAP" -Y "tcp.analysis.spurious_retransmission" 2>/dev/null | wc -l)
echo "    超时重传: $RTO 个"
echo "    快重传:   $FAST 个"
echo "    重复ACK:  $DUPACK 个"
echo "    伪重传:   $SPUR 个"

echo ""
echo "==> (3) 部分 ACK 抽样（确认号未推进到最新已发数据，说明中间有段丢失）"
tshark -r "$PCAP" -Y "tcp.analysis.duplicate_ack || tcp.analysis.retransmission" -T fields \
    -e frame.number -e ip.src -e tcp.ack -e tcp.len 2>/dev/null | head -10

echo ""
echo "==> (4) 重传机制解读"
cat <<'EOF'
   超时重传（RTO）:
     - 触发时机: 发送段后启动定时器，RTO（动态计算，通常数百ms~数s）
       内未收到 ACK，重传"发送窗口内全部未确认段"；
     - 报文特征: 与原段相同 seq/len，与原段间隔 >= RTO；
     - 触发后进入慢启动（cwnd 重置为 1 MSS）。
   快重传（Fast Retransmit）:
     - 触发时机: 收到 3 个重复 ACK（dup ack）立即重传丢失段，不等 RTO；
     - 报文特征: 重传前可见连续 3 个相同 ack 的重复 ACK；
     - 触发后进入快恢复（cwnd 减半），效率高于超时重传。
   部分 ACK（Partial ACK）:
     - 特征: ACK 确认号只推进到已收数据的中间位置（< 最新已发 seq），
       表明接收方只收到部分数据，发送方据此继续重传剩余段。
   序号/确认号规律:
     - 重传段 seq 与原段相同（同一字节重发）；
     - 每收到一个 dup ack，确认号不变（都指向丢失段的起始序号）；
     - 丢失段被成功重传后，ACK 确认号一次性跳过丢失段继续推进。
EOF

# ------------------------------------------------------------
# 预期实验现象:
#   (1)(2) 在 10% 随机丢包下传输 100K（约 70 段），统计输出:
#     - 超时重传若干个（间隔明显大于普通段间间隔）；
#     - 快重传若干个（其前必有 >=3 个重复 ACK）；
#     - 重复 ACK 数量明显多于重传数（3 个 dup ack 触发 1 次快重传）；
#   (3) 部分 ACK 的确认号落在已发数据中间，证明接收方中间缺段；
#   (4) 结合解读可完成实验报告的机制分析。
#   若某类重传未捕获（指导书补充说明）:
#     - 重复执行 step7_tcp_transfer.sh 重新实验；
#     - 或调整 step3_netem_loss.sh 的丢包概率（如 15%/20%）再试。
# ------------------------------------------------------------
