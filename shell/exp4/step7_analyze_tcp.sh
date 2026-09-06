#!/usr/bin/env bash
# =============================================================
# 实验4 步骤7：TCP 报文分析（连接建立/数据传输/连接释放）
# 对应指导书《实验4》步骤7
# 用法: ./step7_analyze_tcp.sh [pcap，默认 /tmp/exp4_tcp.pcap]
# =============================================================
set -euo pipefail
PCAP="${1:-/tmp/exp4_tcp.pcap}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step6_tcp_file_transfer.sh" >&2; exit 1; }

echo "==> (1) TCP 连接建立（三次握手）"
tshark -r "$PCAP" -Y "tcp.flags.syn==1" -T fields \
    -e frame.number -e ip.src -e ip.dst -e tcp.srcport -e tcp.dstport \
    -e tcp.flags -e tcp.seq_raw -e tcp.ack_raw -e tcp.options.mss_val -e tcp.options.wscale.shift \
    2>/dev/null | head -5

echo ""
echo "==> (2) 数据传输阶段（统计各方向数据段与字节数）"
tshark -r "$PCAP" -Y "tcp.len>0" -T fields \
    -e ip.src -e tcp.srcport -e tcp.len 2>/dev/null \
    | awk '{cnt[$1]++; sum[$1]+=$3} END {for (s in sum) printf "    %s: %d 个数据段, 共 %d 字节\n", s, cnt[s], sum[s]}'

echo ""
echo "==> (3) TCP 连接释放（FIN 报文，四次挥手）"
tshark -r "$PCAP" -Y "tcp.flags.fin==1" -T fields \
    -e frame.number -e ip.src -e tcp.flags -e tcp.seq_raw -e tcp.ack_raw \
    2>/dev/null | head -6

echo ""
echo "==> (4) TCP 首部关键字段抽样（前 5 个报文）"
tshark -r "$PCAP" -Y "tcp" -T fields \
    -e frame.number -e tcp.srcport -e tcp.dstport -e tcp.seq -e tcp.ack \
    -e tcp.window_size_value -e tcp.flags -e tcp.hdr_len 2>/dev/null | head -5

echo ""
echo "==> (5) TCP 首部结构解读"
cat <<'EOF'
    0        4        8        16       24       31
   +---------------------------------------------------+
   |   源端口(2B)      |   目的端口(2B)    |
   +---------------------------------------------------+
   |            序号 seq (4B)                          |
   +---------------------------------------------------+
   |            确认号 ack (4B)                        |
   +---------------------------------------------------+
   |数据偏移|保留 |URG|ACK|PSH|RST|SYN|FIN| 窗口(2B)   |
   +---------------------------------------------------+
   |   校验和(2B)      |   紧急指针(2B)    |
   +---------------------------------------------------+
   |   选项(0-40B): MSS / 窗口扩大 / SACK ...          |
   +---------------------------------------------------+
   连接管理规律:
   - 建立连接(三次握手): SYN(seq=x) -> SYN,ACK(seq=y,ack=x+1) -> ACK(seq=x+1,ack=y+1)
   - 释放连接(四次挥手): FIN,ACK(seq=p,ack=q) -> ACK(q,p+1)
                        -> FIN,ACK(seq=q,ack=p+1) -> ACK(p+1,q+1)
     （中间两步常合并为 FIN,ACK，表现为"三次报文"）
   - 每发送一个字节序号+1；确认号=期望收到的下一个字节序号
EOF

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 恰好 2 个 SYN 报文（客户端 SYN + 服务端 SYN,ACK），
#       SYN 报文携带 MSS 选项（跨路由路径通常 1460 或经 PMTU 调整）与
#       窗口扩大选项（wscale），初始序号 seq_raw 为随机值；
#   (2) H57C->H56A 方向约 3 个数据段、合计 3500 字节（文件回传），
#       每段 ≤MSS；H56A->H57C 方向有少量小段（发送的命令行）；
#   (3) FIN 报文 2 个（双方各一个），配合 ACK 完成四次挥手；
#       若抓到 3 条挥手报文，是中间 ACK 与 FIN 合并所致，属正常；
#   (4) 首部字段表: 数据偏移(首部长度)通常 20~40 字节（含选项），
#       窗口值随传输动态增长（流量控制）。
#   分析结论: TCP 通信必须先建立连接（三次握手）、传输中靠序号/确认号
#   可靠交付、结束后按四次挥手释放 —— 验证 TCP 面向连接的核心特性。
# ------------------------------------------------------------
