#!/usr/bin/env bash
# =============================================================
# 实验6 步骤5+6：RB 双接口抓包 + 构造 UDP 通信触发 IP 分片（自动化版）
# 对应指导书《实验6》步骤5(抓包)、步骤6(nping 触发分片)
# 用法: sudo ./step6_ip_fragment.sh [pcap保存目录，默认 /tmp]
# 说明: 指导书用两个 GUI Wireshark 分别监控 RB 的两个接口；本脚本用
#       两个 tshark 实例实现等价抓包（入接口=未分片原始包，出接口=分片后）。
# =============================================================
set -euo pipefail

NS_H56A="H56A"; NS_H57C="H57C"; NS_RB="RB"
IF_RB_IN="ve-RB-SW56A"    # RB 连接 H56A 侧（观测未分片原始包）
IF_RB_OUT="ve-RB-RA"      # RB 连接 RA 侧（观测分片后转发包）
PCAP_DIR="${1:-/tmp}"
PCAP_IN="$PCAP_DIR/exp6_rb_in.pcap"
PCAP_OUT="$PCAP_DIR/exp6_rb_out.pcap"
SERVER_IP="192.168.57.254"
PORT=4499; CPORT=40321; DLEN=1400

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -q "$NS_RB" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }

echo "==> 步骤5: 在 RB 上开启双接口抓包（两个 tshark，等价两个 GUI Wireshark）"
ip netns exec "$NS_RB" tshark -i "$IF_RB_IN"  -w "$PCAP_IN"  >/dev/null 2>&1 &
TS_IN=$!
ip netns exec "$NS_RB" tshark -i "$IF_RB_OUT" -w "$PCAP_OUT" >/dev/null 2>&1 &
TS_OUT=$!
sleep 2

echo "==> 步骤6(1): H57C 开启 UDP 服务端（ncat -lvu $PORT）"
ip netns exec "$NS_H57C" ncat -lvu "$PORT" > /tmp/exp6_server.log 2>&1 &
SRV_PID=$!
sleep 1

echo "==> 步骤6(2): H56A 用 nping 发送 $DLEN 字节数据的 UDP 报文（触发分片）"
ip netns exec "$NS_H56A" nping --udp -p "$PORT" -g "$CPORT" -c 1 --data-length "$DLEN" "$SERVER_IP" 2>&1 | tail -8

sleep 2
echo "==> 停止抓包与服务端"
kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true
kill "$TS_IN" 2>/dev/null || true;   wait "$TS_IN" 2>/dev/null || true
kill "$TS_OUT" 2>/dev/null || true;  wait "$TS_OUT" 2>/dev/null || true
ls -l "$PCAP_IN" "$PCAP_OUT"

# ------------------------------------------------------------
# 预期实验现象:
#   步骤6(2) nping 输出:
#     "SENT (x.xxxx s) UDP 192.168.56.126:40321 > 192.168.57.254:4499
#      ... 1400 bytes"
#     共发送 1 个 1400 字节载荷的 UDP 报文；
#   pcap_in  (RB 入接口): 1 个未分片的原始 IP 分组，
#     总长度 = 20(IP头) + 8(UDP头) + 1400(数据) = 1428 字节 > MTU 1000；
#   pcap_out (RB 出接口): 2 个 IP 分片，
#     片1: 总长 1000（IP头20 + 数据980，实际按8字节对齐取976+4填充对齐，
#          MF=1，片偏移=0）；
#     片2: 总长 = 20 + (1408-976) = 452，MF=0（最后一片），片偏移=976/8=122；
#     两片 IP identification 相同、协议=UDP(17)，仅 UDP 首部在片1 中。
#   若出接口只抓到 1 个包: 检查 MTU 是否两侧都改为 1000。
# ------------------------------------------------------------
