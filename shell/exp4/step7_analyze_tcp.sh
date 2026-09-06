#!/usr/bin/env bash
# =============================================================
# 实验4 步骤7：TCP 报文分析（连接建立/数据传输/连接释放）
# 对应指导书《实验4》步骤7
# 用法: ./step7_analyze_tcp.sh [pcap，默认 /tmp/exp4_tcp.pcap]
# =============================================================
set -euo pipefail
PCAP="${1:-/tmp/exp4_tcp.pcap}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step6_tcp_file_transfer.sh" >&2; exit 1; }

# 校验 pcap 可读且含 TCP 报文，避免 pcap 损坏/为空时"成功"输出空结果
if ! tshark -r "$PCAP" -Y tcp -c 1 >/dev/null 2>&1; then
    echo "[错误] $PCAP 无 TCP 报文或文件损坏，请重新运行 step6_tcp_file_transfer.sh" >&2
    exit 1
fi

# 注意: 不用 `tshark | head`（set -o pipefail 下 head 提前退出会令 tshark 收到
# SIGPIPE、管道返回 141，set -e 中断脚本）；改用 tshark 自身 -c 限条数。
# 各段均按 tcp.port==4499 过滤，避免混入无关 TCP 流量。

echo "==> (1) TCP 连接建立（三次握手）"
tshark -r "$PCAP" -Y "tcp.flags.syn==1 && tcp.port == 4499" -T fields \
    -e frame.number -e ip.src -e ip.dst -e tcp.srcport -e tcp.dstport \
    -e tcp.flags -e tcp.seq_raw -e tcp.ack_raw -e tcp.options.mss_val -e tcp.options.wscale.shift \
    -c 5

echo ""
echo "==> (2) 数据传输阶段（统计各方向数据段与字节数）"
tshark -r "$PCAP" -Y "tcp.len>0 && tcp.port == 4499" -T fields \
    -e ip.src -e tcp.srcport -e tcp.len \
    | awk '{cnt[$1]++; sum[$1]+=$3} END {for (s in sum) printf "    %s: %d 个数据段, 共 %d 字节\n", s, cnt[s], sum[s]}'

echo ""
echo "==> (3) TCP 连接释放（FIN 报文，四次挥手）"
tshark -r "$PCAP" -Y "tcp.flags.fin==1 && tcp.port == 4499" -T fields \
    -e frame.number -e ip.src -e tcp.flags -e tcp.seq_raw -e tcp.ack_raw \
    -c 6

echo ""
echo "==> (4) TCP 首部关键字段抽样（前 5 个报文）"
tshark -r "$PCAP" -Y "tcp.port == 4499" -T fields \
    -e frame.number -e tcp.srcport -e tcp.dstport -e tcp.seq -e tcp.ack \
    -e tcp.window_size_value -e tcp.flags -e tcp.hdr_len -c 5

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
   注: 标志位完整为 9 位（NS/ECE/CWR/URG/ACK/PSH/RST/SYN/FIN），
       4 位数据偏移 + 6(或3)位保留 + 9 位标志 = 16 位控制字段；
       上图为教学简化示意，Wireshark 中以 tcp.flags 数值呈现。
   连接管理规律:
   - 建立连接(三次握手): SYN(seq=x) -> SYN,ACK(seq=y,ack=x+1) -> ACK(seq=x+1,ack=y+1)
   - 释放连接(四次挥手): FIN,ACK(seq=p,ack=q) -> ACK(q,p+1)
                        -> FIN,ACK(seq=q,ack=p+1) -> ACK(p+1,q+1)
     （中间两步常合并为 FIN,ACK，表现为"三次报文"）
   - 每发送一个字节序号+1；确认号=期望收到的下一个字节序号
EOF

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 客户端 SYN + 服务端 SYN,ACK 两个 SYN 报文（若 SYN 重传会更多），
#       SYN 报文携带 MSS 选项（跨路由路径通常 1460 或经 PMTU 调整）与
#       窗口扩大选项（wscale），初始序号 seq_raw 为随机值；
#   (2) H57C->H56A 方向约 3 个数据段、合计 3500 字节（文件回传），
#       每段 ≤MSS；H56A->H57C 方向有少量小段（发送的命令行）；
#   (3) FIN 报文 2 个（服务端先发 FIN——shell 正常退出触发；客户端随后
#       也发 FIN），配合 ACK 完成四次挥手；
#       若抓到 3 条挥手报文，是中间 ACK 与 FIN 合并所致，属正常；
#   (4) 首部字段表: 数据偏移(首部长度)通常 20~40 字节（含选项），
#       窗口值随传输动态增长（流量控制）。
#   分析结论: TCP 通信必须先建立连接（三次握手）、传输中靠序号/确认号
#   可靠交付、结束后按四次挥手释放 —— 验证 TCP 面向连接的核心特性。
# ------------------------------------------------------------
