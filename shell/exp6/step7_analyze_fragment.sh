#!/usr/bin/env bash
# =============================================================
# 实验6 步骤7：IP 分片分析（分片前后 IP 首部字段对比）
# 对应指导书《实验6》步骤7
# 用法: ./step7_analyze_fragment.sh [入pcap] [出pcap]
#       默认 /tmp/exp6_rb_in.pcap /tmp/exp6_rb_out.pcap
# =============================================================
set -euo pipefail
PCAP_IN="${1:-/tmp/exp6_rb_in.pcap}"
PCAP_OUT="${2:-/tmp/exp6_rb_out.pcap}"
[ -f "$PCAP_IN" ] || { echo "[错误] 找不到 $PCAP_IN，先运行 step6_ip_fragment.sh" >&2; exit 1; }

echo "==> (1) 分片前：RB 入接口的原始 IP 分组"
tshark -r "$PCAP_IN" -Y "ip" -T fields \
    -e frame.number -e ip.id -e ip.len -e ip.ttl -e ip.flags.mf -e ip.flags.df \
    -e ip.frag_offset -e ip.proto -e ip.src -e ip.dst 2>/dev/null

echo ""
echo "==> (2) 分片后：RB 出接口的 IP 分片"
tshark -r "$PCAP_OUT" -Y "ip" -T fields \
    -e frame.number -e ip.id -e ip.len -e ip.ttl -e ip.flags.mf -e ip.flags.df \
    -e ip.frag_offset -e ip.proto -e ip.src -e ip.dst 2>/dev/null

echo ""
echo "==> (3) IP 首部结构解读"
cat <<'EOF'
    0        4        8        16       19          31
   +--------+--------+--------+--------+-------------+
   | 版本(4b)|首部长度 |  区分服务(8B)   | 总长度(16b)  |
   +--------+--------+--------+---------------------+
   |        标识 identification (16b)                  |
   +--------+--------+--------------------------------+
   | 标志(3b)|      片偏移 fragment offset (13b)        |
   +--------+--------+--------------------------------+
   |  TTL(8b)  |  协议(8b: 17=UDP)  |  首部校验和(16b)   |
   +---------------------------------------------------+
   |                源 IP 地址 (32b)                    |
   +---------------------------------------------------+
   |                目的 IP 地址 (32b)                  |
   +---------------------------------------------------+
   标志位: DF(Don't Fragment)=1 禁止分片; MF(More Fragment)=1 后面还有分片
   片偏移: 以 8 字节为单位，指出本片数据在原分组数据中的相对位置
EOF

echo ""
echo "==> (4) 分片前后字段变化对比要点"
cat <<'EOF'
   字段            分片前(原始包)         分片后(2个分片)
   ------------------------------------------------------------
   ip.id           同一标识 X             两片均为 X（重组依据）
   ip.len          1428                  片1=1000, 片2=452
   ip.flags.mf     0                     片1=1(还有后续), 片2=0(最后一片)
   ip.frag_offset  0                     片1=0, 片2=122(=976/8)
   ip.ttl          T(如64)               两片均 T-1（RB 转发减1）
   ip.proto        17(UDP)               两片均 17
   UDP 首部        完整(8B)              仅片1 携带，片2 无 UDP 头
   数据            1400B                 片1=976B + 片2=432B（8字节对齐）
   重组: 目的主机按 ip.id 相同 + 片偏移排序 + MF=0 结束 重组出原分组
EOF

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 入接口 1 个分组: ip.len=1428, mf=0, frag_offset=0, ttl=T；
#   (2) 出接口 2 个分片:
#       片1: ip.len=1000, mf=1, frag_offset=0, ttl=T-1；
#       片2: ip.len=452,  mf=0, frag_offset=122, ttl=T-1；
#       两片 ip.id 相同（重组标识）、proto 均为 17(UDP)；
#   (3)(4) 对照解读表可完成 IP 首部各字段与分片机制分析。
#   结论: IP 分片发生在转发路由器的出接口（受 MTU 限制），
#   分片不改变应用层数据，目的主机负责重组。
# ------------------------------------------------------------
