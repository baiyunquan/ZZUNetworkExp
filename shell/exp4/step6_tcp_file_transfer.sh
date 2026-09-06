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

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -q "$NS_H57C" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }
ip netns exec "$NS_H57C" test -f /root/3500.dat || { echo "[错误] 测试文件不存在，先运行 step4_create_testfile.sh" >&2; exit 1; }

echo "==> 步骤5: 在 H57C 上启动抓包（tshark，等价 GUI 选 $IF_H57C）"
ip netns exec "$NS_H57C" tshark -i "$IF_H57C" -w "$PCAP" >/dev/null 2>&1 &
TS_PID=$!
sleep 2

echo "==> 步骤6(1): 在 H57C 上开启 TCP 服务端（ncat -e /bin/sh -lv $PORT）"
ip netns exec "$NS_H57C" ncat -e /bin/sh -lv "$PORT" > /tmp/exp4_server.log 2>&1 &
SRV_PID=$!
sleep 1

echo "==> 步骤6(2)(3): H56A 客户端连接并发送 cat 3500.dat，接收文件回传"
echo "cat /root/3500.dat" | timeout 15 ip netns exec "$NS_H56A" ncat "$SERVER_IP" "$PORT" > "$RECV_FILE" 2>/dev/null || true
RECV_SIZE=$(stat -c %s "$RECV_FILE" 2>/dev/null || echo 0)
echo "    客户端接收文件大小: $RECV_SIZE 字节（期望 3500）"

if [ "$RECV_SIZE" -eq 3500 ]; then
    echo "    文件跨网络传输成功 ✓"
else
    echo "    [提示] 大小不符，可检查服务端日志 /tmp/exp4_server.log"
fi

echo "==> 步骤6(4): 连接释放（客户端 EOF 触发 FIN，观察四次挥手）"
sleep 2
kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true
kill "$TS_PID" 2>/dev/null || true;  wait "$TS_PID" 2>/dev/null || true
ls -l "$PCAP"

# ------------------------------------------------------------
# 预期实验现象:
#   步骤6(1): 服务端输出 "Listening on 0.0.0.0:4499"（监听模式）；
#   (2)(3): 客户端连接后，"cat /root/3500.dat" 经 TCP 发送到 H57C 的
#           shell 执行，文件内容经 TCP 连接回传，客户端收到 3500 字节
#           —— 远程 shell + 跨网络文件传输成功；
#   (4): 客户端 stdin EOF 后发送 FIN 主动关闭，服务端回 ACK+FIN，
#        连接按四次挥手释放；
#   pcap (exp4_tcp.pcap) 中完整可见:
#     - 三次握手: SYN -> SYN,ACK -> ACK（含 MSS/窗口扩大/SACK 选项）；
#     - 数据传输: 多个 ACK 数据段（3500B 约分 3 段，每段 ≤MSS）；
#     - 四次挥手: FIN,ACK -> ACK -> FIN,ACK -> ACK（或合并为三次报文）。
#   交互式操作方法（对应指导书原始步骤）:
#     终端1: ip netns exec H57C bash -> ncat -e /bin/sh -lv 4499
#     终端2: ip netns exec H56A bash -> ncat 192.168.57.254 4499
#     终端2 输入 cat 3500.dat 回车 -> 文件内容回传到终端2
#     传输完毕后先在 H57C、再在 H56A 按 Ctrl+C，观察连接释放。
# ------------------------------------------------------------
