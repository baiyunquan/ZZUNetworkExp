#!/usr/bin/env bash
# =============================================================
# 实验2 步骤3：过滤流量，追踪 HTTP 流，分析 HTTP 报文格式
# 对应指导书《实验2》步骤3 (1)-(3)
# 用法: ./step3_filter_trace.sh [pcap] [keylog]
#       默认: ./exp2_https.pcap ./myssl.log（步骤2 的产物）
# =============================================================
set -euo pipefail
SITE="www.zzu.edu.cn"
PCAP="${1:-exp2_https.pcap}"
KEYLOG="${2:-myssl.log}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step2_tls_capture.sh" >&2; exit 1; }

DEC="-o tls.keylog_file:$KEYLOG"
[ -f "$KEYLOG" ] || DEC=""

# HTTP/1.1 与 HTTP/2 双兼容的 Host 过滤（解密后 HTTP/2 的 Host 在 :authority 伪首部）
HOST_FILTER="(http.host == \"$SITE\") || (http2.header.name == \":authority\" && http2.header.value == \"$SITE\")"

# 由收集到的全部服务器 IP 构造括号包裹的过滤器
# （括号必须显式加：&& 优先级高于 ||，否则组合条件语义错误）
build_filter() {
    local f=""
    for ip in $IPV4_ZZU; do f="${f:+$f || }ip.addr == $ip"; done
    for ip in $IPV6_ZZU; do f="${f:+$f || }ipv6.addr == $ip"; done
    echo "( $f )"
}

echo "==> (1) 过滤 Host == $SITE（对应显示过滤器，得到服务器 IP）"
echo "    --- IPv4_zzu（目的 IPv4 地址）---"
tshark -r "$PCAP" $DEC -Y "$HOST_FILTER" -T fields -e ip.dst 2>/dev/null | sort -u | grep -v '^$' || true
echo "    --- IPv6_zzu（目的 IPv6 地址）---"
tshark -r "$PCAP" $DEC -Y "$HOST_FILTER" -T fields -e ipv6.dst 2>/dev/null | sort -u | grep -v '^$' || true

# 服务器可能有多个 A/AAAA 记录（zzu 为 2+2），全部收集，浏览器可能连到任一 IP
IPV4_ZZU=$(tshark -r "$PCAP" $DEC -Y "$HOST_FILTER" -T fields -e ip.dst 2>/dev/null | sort -u | grep -v '^$' | tr '\n' ' ' || true)
IPV6_ZZU=$(tshark -r "$PCAP" $DEC -Y "$HOST_FILTER" -T fields -e ipv6.dst 2>/dev/null | sort -u | grep -v '^$' | tr '\n' ' ' || true)
echo "    记录: IPv4_zzu=${IPV4_ZZU:-无}  IPv6_zzu=${IPV6_ZZU:-无}"

[ -n "${IPV4_ZZU}${IPV6_ZZU}" ] || { echo "[错误] 未提取到服务器 IP，请检查 keylog 是否有效（重跑 step2）" >&2; exit 1; }

echo "==> (2) 过滤服务器参与通信的所有数据包（ip.addr / ipv6.addr == 服务器IP）"
FILTER=$(build_filter)
echo "    过滤器: $FILTER"
tshark -r "$PCAP" $DEC -Y "$FILTER" 2>/dev/null | head -15
echo "    （仅显示前 15 行，完整列表可用 Wireshark 打开 pcap 复现）"

echo "==> (3) 追踪 HTTP 流（等价 GUI: 右键 -> 追踪流 -> HTTP Stream）"
# 注意：HTTPS 流量的 TCP 原始字节流是密文，follow,tcp 只能看到乱码；
# 必须用 follow,tls 配合 keylog，才能展示解密后的会话内容
STREAMS=$(tshark -r "$PCAP" $DEC -Y "(http || http2) && tcp" -T fields -e tcp.stream 2>/dev/null | sort -un | head -3 || true)
for s in $STREAMS; do
    echo "    ===== TCP 流 #$s 的会话内容（TLS 解密后） ====="
    tshark -r "$PCAP" $DEC -q -z "follow,tls,ascii,$s" 2>/dev/null | sed -n '1,40p'
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
