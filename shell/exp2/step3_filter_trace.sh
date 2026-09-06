#!/usr/bin/env bash
# =============================================================
# 实验2 步骤3：过滤流量，追踪 HTTP 流，分析 HTTP 报文格式
# 对应指导书《实验2》步骤3 (1)-(3)
# 用法: ./step3_filter_trace.sh [pcap] [keylog]
#       默认: ./exp2_https.pcap ./myssl.log（步骤2 的产物）
# =============================================================
set -euo pipefail
PCAP="${1:-exp2_https.pcap}"
KEYLOG="${2:-myssl.log}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step2_tls_capture.sh" >&2; exit 1; }

DEC="-o tls.keylog_file:$KEYLOG"
[ -f "$KEYLOG" ] || DEC=""

echo "==> (1) 过滤 http.host == $SITE（对应显示过滤器，得到服务器 IP）"
echo "    --- IPv4_zzu（目的 IPv4 地址）---"
tshark -r "$PCAP" $DEC -Y "http.host == \"$SITE\"" -T fields -e ip.dst 2>/dev/null | sort -u | grep -v '^$' || true
echo "    --- IPv6_zzu（目的 IPv6 地址）---"
tshark -r "$PCAP" $DEC -Y "http.host == \"$SITE\"" -T fields -e ipv6.dst 2>/dev/null | sort -u | grep -v '^$' || true

IPV4_ZZU=$(tshark -r "$PCAP" $DEC -Y "http.host == \"$SITE\"" -T fields -e ip.dst 2>/dev/null | sort -u | grep -v '^$' | head -1)
IPV6_ZZU=$(tshark -r "$PCAP" $DEC -Y "http.host == \"$SITE\"" -T fields -e ipv6.dst 2>/dev/null | sort -u | grep -v '^$' | head -1)
echo "    记录: IPv4_zzu=${IPV4_ZZU:-无}  IPv6_zzu=${IPV6_ZZU:-无}"

echo "==> (2) 过滤服务器参与通信的所有数据包（ip.addr / ipv6.addr == 服务器IP）"
FILTER="ip.addr == ${IPV4_ZZU:-0.0.0.0}"
[ -n "$IPV6_ZZU" ] && FILTER="$FILTER || ipv6.addr == $IPV6_ZZU"
tshark -r "$PCAP" $DEC -Y "$FILTER" 2>/dev/null | head -15
echo "    （仅显示前 15 行，完整列表可用 Wireshark 打开 pcap 复现）"

echo "==> (3) 追踪 HTTP 流（等价 GUI: 右键 -> 追踪流 -> HTTP Stream）"
STREAMS=$(tshark -r "$PCAP" $DEC -Y "http" -T fields -e tcp.stream 2>/dev/null | sort -un | head -3)
for s in $STREAMS; do
    echo "    ===== TCP 流 #$s 的 HTTP 会话内容 ====="
    tshark -r "$PCAP" $DEC -q -z "follow,tcp,ascii,$s" 2>/dev/null | sed -n '1,40p'
done

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 过滤后得到服务器 IP：IPv4 形如 202.196.64.194（记作 IPv4_zzu）、
#       IPv6 形如 2001:da8:5000:6c00::48（记作 IPv6_zzu）；
#   (2) 过滤出浏览器与服务器之间的全部报文：TCP 三次握手、TLS 握手、
#       解密后的 HTTP 请求/响应、四次挥手；
#   (3) 追踪 HTTP 流后可看到完整会话明文，请求报文格式:
#         GET / HTTP/1.1
#         Host: www.zzu.edu.cn
#         User-Agent: Mozilla/5.0 ...
#         Accept: text/html,...
#         Cookie: ...
#       响应报文格式:
#         HTTP/1.1 200 OK
#         Server: nginx
#         Content-Type: text/html
#         Set-Cookie: ...
#       即"请求行/状态行 + 首部行 + 空行 + 实体体"的标准 HTTP 报文结构。
#   若 (3) 无输出: 说明该流是纯 TLS 未解密，检查 keylog 是否传入。
# ------------------------------------------------------------
