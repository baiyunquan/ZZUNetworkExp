#!/usr/bin/env bash
# =============================================================
# 实验4 步骤5+6：抓包 + TCP 远程 shell 文件传输（自动化版）
# 对应指导书《实验4》步骤5(抓包)、步骤6(TCP服务端/客户端与文件传输)
# 用法: sudo ./step6_tcp_file_transfer.sh [pcap保存目录，默认 /tmp]
# 说明: 指导书用交互终端手动输入 cat 3500.dat；本脚本通过管道向
#       ncat 远程 shell 发送命令实现等价自动化，并用 tshark 抓包。
#       交互式操作方法见脚本末尾注释。
# =============================================================
set -euo pipefail

NS_H56A="H56A"; NS_H57C="H57C"
IF_H57C="ve-H57C"
SERVER_IP="192.168.57.254"
PORT=4499
PCAP_DIR="${1:-/tmp}"
PCAP="$PCAP_DIR/exp4_tcp.pcap"
RECV_FILE="/tmp/exp4_received.dat"
SRV_LOG="/tmp/exp4_server.log"
CLIENT_LOG="/tmp/exp4_client.log"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -qw "$NS_H57C" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }
ip netns exec "$NS_H57C" test -f /root/3500.dat || { echo "[错误] 测试文件不存在，先运行 step4_create_testfile.sh" >&2; exit 1; }

mkdir -p "$PCAP_DIR"

# 清理上次运行残留的服务端/抓包进程，避免端口占用、连到旧进程
pkill -f "ncat -e /bin/sh -lv $PORT" 2>/dev/null || true
pkill -f "tshark -i $IF_H57C" 2>/dev/null || true
sleep 1

# 退出时清理本次后台进程（含 -e 拉起的子 shell，防孤儿进程持有连接）
TS_PID=""; SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && { pkill -P "$SRV_PID" 2>/dev/null || true; kill "$SRV_PID" 2>/dev/null || true; }
    [ -n "$TS_PID" ]  && kill "$TS_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 步骤5: 在 H57C 上启动抓包（tshark，等价 GUI 选 $IF_H57C）"
# stderr 留档而非丢弃；启动后探活
ip netns exec "$NS_H57C" tshark -i "$IF_H57C" -a duration:25 -w "$PCAP" >"$PCAP_DIR/exp4_tshark.log" 2>&1 &
TS_PID=$!
sleep 2
if ! kill -0 "$TS_PID" 2>/dev/null; then
    echo "[错误] tshark 启动失败，日志:" >&2; cat "$PCAP_DIR/exp4_tshark.log" >&2; exit 1
fi

echo "==> 步骤6(1): 在 H57C 上开启 TCP 服务端（ncat -e /bin/sh -lv $PORT）"
ip netns exec "$NS_H57C" ncat -e /bin/sh -lv "$PORT" > "$SRV_LOG" 2>&1 &
SRV_PID=$!
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "[错误] ncat 服务端启动失败，日志:" >&2; cat "$SRV_LOG" >&2; exit 1
fi
# 确认端口真的处于监听状态（不依赖 sleep 时序猜测）
if ! ip netns exec "$NS_H57C" ss -tln "sport = :$PORT" | grep -q "4499"; then
    echo "[错误] 端口 $PORT 未进入监听状态，服务端日志:" >&2; cat "$SRV_LOG" >&2; exit 1
fi

echo "==> 步骤6(2)(3): H56A 客户端连接并发送 cat 3500.dat，接收文件回传"
# 关键: 命令后追加 exit，让远程 /bin/sh 执行完 cat 后正常退出。
# 否则服务端永远不退出、客户端 stdin EOF 后 ncat 挂住直至被 timeout
# SIGTERM 强杀，内核发 RST 而非优雅 FIN —— pcap 里就抓不到四次挥手。
printf 'cat /root/3500.dat\nexit\n' | timeout 20 ip netns exec "$NS_H56A" ncat "$SERVER_IP" "$PORT" > "$RECV_FILE" 2> "$CLIENT_LOG" || true
RECV_SIZE=$(stat -c %s "$RECV_FILE" 2>/dev/null || echo 0)
echo "    客户端接收文件大小: $RECV_SIZE 字节（期望 3500）"

if [ "$RECV_SIZE" -eq 3500 ]; then
    echo "    文件跨网络传输成功 ✓"
else
    echo "    文件传输失败/不完整 ✗（客户端日志: $CLIENT_LOG，服务端日志: $SRV_LOG）" >&2
fi

echo "==> 步骤6(4): 连接释放（服务端 shell 正常退出 -> 服务端先发 FIN，观察四次挥手）"
sleep 3
cleanup
ls -l "$PCAP"

if [ "$RECV_SIZE" -eq 3500 ]; then
    exit 0
else
    echo "==> 实验未通过（文件大小不符），请查看日志后重试" >&2
    exit 1
fi

# ------------------------------------------------------------
# 预期实验现象:
#   步骤6(1): 服务端输出 "Listening on 0.0.0.0:4499"（监听模式）；
#   (2)(3): 客户端连接后，"cat /root/3500.dat" 经 TCP 发送到 H57C 的
#           shell 执行，文件内容经 TCP 连接回传，客户端收到 3500 字节
#           —— 远程 shell + 跨网络文件传输成功；
#   (4): 服务端 /bin/sh 执行完 exit 正常退出 -> 服务端先发 FIN/ACK，
#        客户端 ACK 后也发 FIN，连接按四次挥手优雅释放（非 RST）；
#   pcap (exp4_tcp.pcap) 中完整可见:
#     - 三次握手: SYN -> SYN,ACK -> ACK（含 MSS/窗口扩大/SACK 选项）；
#     - 数据传输: 多个 ACK 数据段（3500B 约分 3 段，每段 ≤MSS）；
#     - 四次挥手: FIN,ACK -> ACK -> FIN,ACK -> ACK（或合并为三次报文）。
#   注意: 自动化路径上由"服务端正常退出"触发挥手；若用 timeout 强杀
#   进程（SIGTERM），内核会发 RST 而非 FIN，pcap 中将看不到挥手序列。
#   交互式操作方法（对应指导书原始步骤）:
#     终端1: ip netns exec H57C bash -> ncat -e /bin/sh -lv 4499
#     终端2: ip netns exec H56A bash -> ncat 192.168.57.254 4499
#     终端2 输入 cat 3500.dat 回车 -> 文件内容回传到终端2
#     传输完毕后先在 H57C、再在 H56A 按 Ctrl+C，观察连接释放。
# ------------------------------------------------------------
