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
SITE="www.zzu.edu.cn"
# HTTP/1.1 与 HTTP/2 双兼容（解密后 HTTP/2 的 Host 在 :authority 伪首部）
HOST_FILTER="(http.host == \"$SITE\") || (http2.header.name == \":authority\" && http2.header.value == \"$SITE\")"
# 服务器可能有多个 A/AAAA 记录（zzu 为 2+2），全部收集，浏览器可能连到任一 IP
IPV4_ZZU=$(tshark -r "$PCAP" $DEC -Y "$HOST_FILTER" -T fields -e ip.dst 2>/dev/null | sort -u | grep -v '^$' | tr '\n' ' ' || true)
IPV6_ZZU=$(tshark -r "$PCAP" $DEC -Y "$HOST_FILTER" -T fields -e ipv6.dst 2>/dev/null | sort -u | grep -v '^$' | tr '\n' ' ' || true)
echo "    IPv4_zzu=${IPV4_ZZU:-无}  IPv6_zzu=${IPV6_ZZU:-无}"

[ -n "${IPV4_ZZU}${IPV6_ZZU}" ] || { echo "[错误] 未提取到服务器 IP，请检查 keylog 是否有效（重跑 step2）" >&2; exit 1; }

# 括号必须显式加：&& 优先级高于 ||，不加括号时 SYN 条件只作用于最后一个分支
FILTER="( $(for ip in $IPV4_ZZU; do printf 'ip.addr == %s || ' "$ip"; done; for ip in $IPV6_ZZU; do printf 'ipv6.addr == %s || ' "$ip"; done | sed 's/ || $//') )"
echo "    过滤器: $FILTER"

echo "==> (2) TCP 会话统计（等价 GUI: 统计->会话->TCP）"
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
