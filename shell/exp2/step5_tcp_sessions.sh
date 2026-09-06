#!/usr/bin/env bash
# =============================================================
# 实验2 步骤5：过滤流量，分析 TCP 并发连接数
# 对应指导书《实验2》步骤5 (1)-(2)
# 用法: ./step5_tcp_sessions.sh [pcap] [keylog]
# 说明: GUI 操作为 统计->会话->TCP 标签页；本脚本用 tshark 的
#       conv/talkers 统计实现等价分析。
# =============================================================
set -euo pipefail
PCAP="${1:-exp2_https.pcap}"
KEYLOG="${2:-myssl.log}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step2_tls_capture.sh" >&2; exit 1; }

DEC="-o tls.keylog_file:$KEYLOG"
[ -f "$KEYLOG" ] || DEC=""

echo "==> (1) 过滤服务器参与通信的数据包"
IPV4_ZZU=$(tshark -r "$PCAP" $DEC -Y "http.host == \"www.zzu.edu.cn\"" -T fields -e ip.dst 2>/dev/null | sort -u | grep -v '^$' | head -1)
IPV6_ZZU=$(tshark -r "$PCAP" $DEC -Y "http.host == \"www.zzu.edu.cn\"" -T fields -e ipv6.dst 2>/dev/null | sort -u | grep -v '^$' | head -1)
echo "    IPv4_zzu=${IPV4_ZZU:-无}  IPv6_zzu=${IPV6_ZZU:-无}"

echo "==> (2) TCP 会话统计（等价 GUI: 统计->会话->TCP）"
FILTER="ip.addr == ${IPV4_ZZU:-0.0.0.0}"
[ -n "$IPV6_ZZU" ] && FILTER="$FILTER || ipv6.addr == $IPV6_ZZU"
tshark -r "$PCAP" $DEC -q -z "conv,tcp,$FILTER" 2>/dev/null | head -25

echo "==> (3) TCP 并发连接数分析"
N_STREAMS=$(tshark -r "$PCAP" $DEC -Y "$FILTER && tcp.flags.syn==1 && tcp.flags.ack==0" \
    -T fields -e tcp.stream 2>/dev/null | sort -un | wc -l)
echo "    本次访问共发起 $N_STREAMS 条 TCP 连接（SYN 握手计数）"
echo "    各连接的本地端口（并发连接的标识）:"
tshark -r "$PCAP" $DEC -Y "$FILTER && tcp.flags.syn==1 && tcp.flags.ack==0" \
    -T fields -e tcp.srcport 2>/dev/null | sort -un | tr '\n' ' '; echo

# ------------------------------------------------------------
# 预期实验现象:
#   (2) 会话统计表列出每条 TCP 会话的 地址A<->地址B、收发帧数/字节数、
#       会话起止时间，通常可见 3~8 条到服务器 443 端口的会话；
#   (3) 浏览器对同一站点会并发建立多条 TCP 连接（每条由不同的本地
#       临时端口标识，如 45102、45106、45108...），用于并行加载
#       HTML/JS/CSS/图片等资源，缩短页面总加载时间；
#       HTTP/2 场景下连接数较少（多路复用），HTTP/1.1 场景下较多
#       （浏览器通常并发 6 条左右）。
#   分析要点: 并发连接数 = 不同本地端口数；连接复用（Keep-Alive）时
#   一个端口可承载多次请求；对比 GUI "统计->会话->TCP" 的会话条目
#   应与本脚本统计一致。
# ------------------------------------------------------------
