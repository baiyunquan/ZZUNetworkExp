#!/usr/bin/env bash
# =============================================================
# 实验3 步骤3+4+5：模拟主机终端、开启抓包、搭建 UDP 通信（自动化版）
# 对应指导书《实验3》步骤3(模拟终端)、步骤4(抓包)、步骤5(UDP通信)
# 用法: sudo ./step3_udp_comm.sh [pcap保存目录，默认 /tmp]
# 说明: 指导书用交互终端手动收发；本脚本用 ncat -e /bin/cat 回显服务端
#       实现等价的双向收发，并用 tshark 在 H57C 上抓包（等价 GUI 抓包）。
#       交互式操作方法见脚本末尾注释。
# =============================================================
set -euo pipefail

NS_H56A="H56A"; NS_H57C="H57C"
IF_H57C="ve-H57C"
SERVER_IP="192.168.57.254"   # H57C
PORT=4499
PCAP_DIR="${1:-/tmp}"
PCAP="$PCAP_DIR/exp3_udp.pcap"
MSG_FROM_CLIENT="hello-udp-from-H56A"
MSG_FROM_SERVER="hi-udp-from-H57C"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -q "$NS_H57C" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }

echo "==> 步骤4: 在 H57C 上启动抓包（tshark，等价 GUI Wireshark 选 $IF_H57C）"
ip netns exec "$NS_H57C" tshark -i "$IF_H57C" -w "$PCAP" >/dev/null 2>&1 &
TS_PID=$!
sleep 2

echo "==> 步骤5(1): 在 H57C 上开启 UDP 服务端（ncat -lvu $PORT，回显模式）"
ip netns exec "$NS_H57C" ncat -e /bin/cat -lvu "$PORT" > /tmp/exp3_server.log 2>&1 &
SRV_PID=$!
sleep 1

echo "==> 步骤5(2)(3): 在 H56A 上启动 UDP 客户端并发送消息"
CLIENT_OUT=$(echo "$MSG_FROM_CLIENT" | timeout 6 ip netns exec "$NS_H56A" ncat -u "$SERVER_IP" "$PORT" 2>/dev/null || true)
echo "    客户端发送: $MSG_FROM_CLIENT"
echo "    客户端收到: ${CLIENT_OUT:-（无回显）}"

echo "==> 步骤5(4): 服务端（H57C）向客户端回发消息验证"
# 回显服务端已自动将收到的内容原样返回，上面 CLIENT_OUT 即服务端回发内容
if [ "${CLIENT_OUT:-}" = "$MSG_FROM_CLIENT" ]; then
    echo "    双向通信验证 ✓（服务端回发内容与客户端发送一致）"
else
    echo "    [提示] 回显验证未通过，可改用交互终端方式（见脚本末尾注释）"
fi

sleep 2
echo "==> 停止抓包与服务端"
kill "$TS_PID" 2>/dev/null || true;  wait "$TS_PID" 2>/dev/null || true
kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true
ls -l "$PCAP"

echo "==> 服务端收到的内容（/tmp/exp3_server.log 无回显输出，实际数据见 pcap）"

# ------------------------------------------------------------
# 预期实验现象:
#   步骤3: 两个终端分别执行 ip netns exec H56A bash / ip netns exec H57C bash
#          后，提示符所在环境即为两台"虚拟主机"，ifconfig 只能看到本机
#          VETH 接口，exit 退出模拟环境；
#   步骤4: Wireshark（或本脚本 tshark）在 H57C 的 ve-H57C 接口开始抓包；
#   步骤5: 客户端发送一行字符后，服务端收到并回显，客户端收到相同内容
#          —— 双向 UDP 通信成功；
#   抓包文件 exp3_udp.pcap 中可见:
#     - UDP 报文: 源IP=192.168.56.126，目的IP=192.168.57.254，
#       源端口(客户端临时端口)、目的端口=4499；
#     - 回程报文: 源端口=4499，目的端口=客户端临时端口；
#     - 中间无握手/确认报文（对比 TCP），体现 UDP 无连接特性；
#     - UDP 首部仅 8 字节: 源端口、目的端口、长度、校验和各 2 字节。
#   交互式操作方法（对应指导书原始步骤）:
#     终端1: ip netns exec H57C bash  ->  ncat -lvu 4499
#     终端2: ip netns exec H56A bash  ->  ncat -u 192.168.57.254 4499
#     之后在两个终端交替输入字符回车，即可双向收发。
# ------------------------------------------------------------
