#!/usr/bin/env bash
# =============================================================
# 实验5 步骤5+6+7：创建测试文件、抓包、TCP 大文件传输（自动化版）
# 对应指导书《实验5》步骤5(建文件)、步骤6(抓包)、步骤7(传输)
# 用法: sudo ./step7_tcp_transfer.sh [pcap保存目录，默认 /tmp] [超时秒数，默认120]
# 说明: 指导书用交互终端 + GUI Wireshark；本脚本用重定向 + tshark
#       实现等价自动化。交互式方法见脚本末尾注释。
# =============================================================
set -euo pipefail

NS_H56A="H56A"; NS_H57C="H57C"
IF_H56A="ve-H56A"
SERVER_IP="192.168.57.254"
PORT=4499
PCAP_DIR="${1:-/tmp}"
TIMEOUT="${2:-120}"
PCAP="$PCAP_DIR/exp5_tcp.pcap"
SRC_FILE="/root/100K_56A.dat"
DST_FILE="/root/100K_57C.dat"
SRV_LOG="$PCAP_DIR/exp5_server.log"
CLIENT_LOG="$PCAP_DIR/exp5_client.log"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -qw "$NS_H56A" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }
ip netns list | grep -qw "$NS_H57C" || { echo "[错误] 拓扑未创建（缺少 H57C），先运行 create_topology.sh create" >&2; exit 1; }

mkdir -p "$PCAP_DIR"

# 清理上次运行残留的进程，避免端口占用
pkill -f "ncat -lv $PORT" 2>/dev/null || true
pkill -f "tshark -i $IF_H56A" 2>/dev/null || true
sleep 1

# 退出时清理本次后台进程
TS_PID=""; SRV_PID=""
cleanup() { kill "$TS_PID" "$SRV_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> 步骤5: 在 H56A 上创建 100K 测试文件"
ip netns exec "$NS_H56A" truncate -s 100K "$SRC_FILE"
ip netns exec "$NS_H56A" stat -c '%s 字节: %n' "$SRC_FILE"

echo "==> 步骤6: 在 H56A 上启动抓包（tshark，等价 GUI 选 $IF_H56A）"
# stderr 留档而非丢弃；启动后探活，避免 tshark 启动失败仍"照常完成"
ip netns exec "$NS_H56A" tshark -i "$IF_H56A" -a duration:180 -w "$PCAP" >"$PCAP_DIR/exp5_tshark.log" 2>&1 &
TS_PID=$!
sleep 2
if ! kill -0 "$TS_PID" 2>/dev/null; then
    echo "[错误] tshark 启动失败，日志:" >&2; cat "$PCAP_DIR/exp5_tshark.log" >&2; exit 1
fi

echo "==> 步骤7(1): H57C 开启 TCP 服务端（ncat -lv $PORT > 100K_57C.dat）"
ip netns exec "$NS_H57C" ncat -lv "$PORT" > "$DST_FILE" 2>"$SRV_LOG" &
SRV_PID=$!
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "[错误] ncat 服务端启动失败，日志:" >&2; cat "$SRV_LOG" >&2; exit 1
fi
if ! ip netns exec "$NS_H57C" ss -tln "sport = :$PORT" | grep -q "4499"; then
    echo "[错误] 端口 $PORT 未进入监听状态，服务端日志:" >&2; cat "$SRV_LOG" >&2; exit 1
fi

echo "==> 步骤7(2): H56A 客户端发送文件（ncat $SERVER_IP $PORT < 100K_56A.dat）"
# 客户端错误留档；发送完 stdin EOF 后 ncat 会主动发 FIN 断开
timeout "$TIMEOUT" ip netns exec "$NS_H56A" ncat "$SERVER_IP" "$PORT" < "$SRC_FILE" >"$CLIENT_LOG" 2>&1 || true
sleep 3

echo "==> 步骤7(3): 传输完毕，客户端自动终止连接"
cleanup

echo "==> 校验传输结果"
DST_SIZE=$(ip netns exec "$NS_H57C" stat -c %s "$DST_FILE" 2>/dev/null || echo 0)
echo "    发送: 102400 字节, 接收: $DST_SIZE 字节"
ls -l "$PCAP"
if [ "$DST_SIZE" -eq 102400 ]; then
    echo "    100K 文件传输成功 ✓（传输过程中经历了丢包与重传）"
    exit 0
else
    echo "    文件传输失败/不完整 ✗（服务端日志: $SRV_LOG，客户端日志: $CLIENT_LOG）" >&2
    echo "    [提示] 10% 丢包下偶发连续丢包会拉长传输时间，可增大 timeout 或降低丢包率重试" >&2
    exit 1
fi

# ------------------------------------------------------------
# 预期实验现象:
#   步骤5: stat 显示 102400 字节（100K）；
#   步骤7: 服务端重定向文件最终为 102400 字节，与源文件一致
#          —— 在 10% 随机丢包环境下 TCP 依然可靠交付全部数据，
#          这正是 TCP 可靠传输机制的价值所在；
#   pcap (exp5_tcp.pcap) 中可见:
#     - 大量数据段（100K/MSS ≈ 70 段）；
#     - 重复 ACK（dup ack）与重传报文（超时重传/快重传）；
#     - 部分 ACK（部分确认）；
#     - 窗口在 65536 上限内动态变化。
#   若传输卡死超时: 10% 丢包下偶发连续丢包会拉长传输时间，
#   可增大 timeout 或降低丢包率后重试。
#   交互式操作方法（对应指导书原始步骤）:
#     终端1: ip netns exec H57C bash -> ncat -lv 4499 > 100K_57C.dat
#     终端2: ip netns exec H56A bash -> ncat 192.168.57.254 4499 < 100K_56A.dat
#     传输完毕客户端自动断开。
# ------------------------------------------------------------
