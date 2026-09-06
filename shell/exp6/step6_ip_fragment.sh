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
ip netns list | grep -qw "$NS_RB" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }

mkdir -p "$PCAP_DIR"
SRV_LOG="$PCAP_DIR/exp6_server.log"

# 删除旧 pcap，防止 step7 拿上次的陈旧数据"成功"分析
rm -f "$PCAP_IN" "$PCAP_OUT"

# 清理上次运行残留进程，避免端口占用
pkill -f "ncat -lvu $PORT" 2>/dev/null || true
pkill -f "tshark -i $IF_RB_IN" 2>/dev/null || true
pkill -f "tshark -i $IF_RB_OUT" 2>/dev/null || true
sleep 1

# 退出时清理本次后台进程
TS_IN=""; TS_OUT=""; SRV_PID=""
cleanup() { kill "$SRV_PID" "$TS_IN" "$TS_OUT" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> 步骤5: 在 RB 上开启双接口抓包（两个 tshark，等价两个 GUI Wireshark）"
# stderr 留档而非丢弃；启动后探活
ip netns exec "$NS_RB" tshark -i "$IF_RB_IN"  -a duration:12 -w "$PCAP_IN"  >"$PCAP_DIR/exp6_tshark_in.log"  2>&1 &
TS_IN=$!
ip netns exec "$NS_RB" tshark -i "$IF_RB_OUT" -a duration:12 -w "$PCAP_OUT" >"$PCAP_DIR/exp6_tshark_out.log" 2>&1 &
TS_OUT=$!
sleep 2
for t in "$TS_IN" "$TS_OUT"; do
    if ! kill -0 "$t" 2>/dev/null; then
        echo "[错误] tshark 启动失败（pid=$t），日志:" >&2
        cat "$PCAP_DIR"/exp6_tshark_*.log >&2
        exit 1
    fi
done

echo "==> 步骤6(1): H57C 开启 UDP 服务端（ncat -lvu $PORT）"
ip netns exec "$NS_H57C" ncat -lvu "$PORT" > "$SRV_LOG" 2>&1 &
SRV_PID=$!
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "[错误] ncat 服务端启动失败，日志:" >&2; cat "$SRV_LOG" >&2; exit 1
fi
if ! ip netns exec "$NS_H57C" ss -uln "sport = :$PORT" | grep -q "4499"; then
    echo "[错误] UDP 端口 $PORT 未进入监听状态，服务端日志:" >&2; cat "$SRV_LOG" >&2; exit 1
fi

echo "==> 步骤6(2): H56A 用 nping 发送 $DLEN 字节数据的 UDP 报文（触发分片）"
ip netns exec "$NS_H56A" nping --udp -p "$PORT" -g "$CPORT" -c 1 --data-length "$DLEN" "$SERVER_IP" 2>&1 | tail -8

sleep 2
echo "==> 停止抓包与服务端"
cleanup

ls -l "$PCAP_IN" "$PCAP_OUT"

# 断言: 两个 pcap 均非空（入=1 个未分片 1428B 原始包，出=2 个分片），不靠人眼看 step7
FRAG_IN=$(tshark -r "$PCAP_IN" -Y "ip.len==1428" -c 1 2>/dev/null | wc -l)
FRAG_OUT=$(tshark -r "$PCAP_OUT" -Y "ip.flags.mf==1 || ip.frag_offset>0" 2>/dev/null | wc -l)
if [ "$FRAG_IN" -ge 1 ] && [ "$FRAG_OUT" -ge 2 ]; then
    echo "==> 分片抓包验证通过 ✓（入接口含 1428B 原始包，出接口含分片）"
    exit 0
else
    echo "==> 分片抓包验证未通过 ✗（FRAG_IN=$FRAG_IN, FRAG_OUT=$FRAG_OUT）" >&2
    echo "    [提示] 检查 step3_set_mtu.sh 是否已将 RB-RA 链路两侧 MTU 改为 1000" >&2
    exit 1
fi

# ------------------------------------------------------------
# 预期实验现象:
#   步骤6(2) nping 输出:
#     "SENT (x.xxxx s) UDP 192.168.56.126:40321 > 192.168.57.254:4499
#      ... 1400 bytes"
#     共发送 1 个 1400 字节载荷的 UDP 报文；
#   pcap_in  (RB 入接口): 1 个未分片的原始 IP 分组，
#     总长度 = 20(IP头) + 8(UDP头) + 1400(数据) = 1428 字节 > MTU 1000；
#   pcap_out (RB 出接口): 2 个 IP 分片，
#     片1: 总长 996（IP头20 + 数据976；分片数据须 8 字节对齐，
#          MTU 1000 - IP头 20 = 980，向下取整到 976 —— IP 分片
#          不存在"填充对齐"，是直接按 8 字节向下取整），MF=1，片偏移=0；
#     片2: 总长 = 20 + (1408-976) = 452，MF=0（最后一片），
#          片偏移 = 976 字节（tshark 输出字节；IP 首部字段本身以
#          8 字节为单位，即 976/8 = 122）；
#     两片 IP identification 相同、协议=UDP(17)，仅 UDP 首部在片1 中。
#   若出接口只抓到 1 个包: 检查 MTU 是否两侧都改为 1000。
# ------------------------------------------------------------
