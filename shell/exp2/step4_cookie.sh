#!/usr/bin/env bash
# =============================================================
# 实验2 步骤4：过滤流量，分析 Cookie 格式和作用
# 对应指导书《实验2》步骤4 (1)-(2)
# 用法: ./step4_cookie.sh [pcap] [keylog]
# =============================================================
set -euo pipefail
PCAP="${1:-exp2_https.pcap}"
KEYLOG="${2:-myssl.log}"
[ -f "$PCAP" ] || { echo "[错误] 找不到 $PCAP，请先运行 step2_tls_capture.sh" >&2; exit 1; }

DEC="-o tls.keylog_file:$KEYLOG"
[ -f "$KEYLOG" ] || DEC=""

# HTTP/1.1 与 HTTP/2 双兼容的过滤器（解密后 HTTP/2 首部经 http2.header.* 提取）
SETCOOKIE_FILTER="(http.set_cookie) || (http2.header.name == \"set-cookie\")"
COOKIE_FILTER="(http.cookie) || (http2.header.name == \"cookie\")"

echo "==> (1) 过滤 set-cookie / cookie 首部行（等价 GUI 显示过滤器）"
echo "    --- 响应中的 Set-Cookie 首部行（服务器 -> 浏览器）---"
tshark -r "$PCAP" $DEC -Y "$SETCOOKIE_FILTER" -T fields \
    -e http.response.code -e http.set_cookie -e http2.header.value 2>/dev/null | head -10 || true

echo "    --- 请求中的 Cookie 首部行（浏览器 -> 服务器）---"
tshark -r "$PCAP" $DEC -Y "$COOKIE_FILTER" -T fields \
    -e http.host -e http.cookie -e http2.header.value 2>/dev/null | head -10 || true

echo "==> (2) Cookie 字段解析（名称=值; 属性）"
tshark -r "$PCAP" $DEC -Y "$SETCOOKIE_FILTER" -T fields -e http.set_cookie -e http2.header.value 2>/dev/null \
    | tr ';' '\n' | sed 's/^ *//' | grep -v '^$' | sort -u | head -15 || true

# ------------------------------------------------------------
# 预期实验现象:
#   (1) 过滤出两类报文:
#       - 含 Set-Cookie 的 HTTP 响应（服务器下发）:
#           HTTP/1.1 200 OK
#           Set-Cookie: __jsluid_h=xxxxx; expires=...; path=/; HttpOnly
#       - 含 Cookie 的 HTTP 请求（浏览器回带）:
#           GET /xxx HTTP/1.1
#           Cookie: __jsluid_h=xxxxx; Hm_lpvt=...
#   (2) 解析出的 Cookie 字段形如:
#       名称=值（如 __jsluid_h=8a1b...）、expires=过期时间、path=作用路径、
#       domain=作用域、HttpOnly/Secure=安全属性。
#   作用分析: 服务器通过 Set-Cookie 下发状态标识，浏览器在后续对同一
#   服务器的请求中通过 Cookie 首部自动回带，使无状态的 HTTP 具备
#   会话保持能力（登录态、个性化、追踪等）。
#   若无输出: 该站点未使用 Cookie 或抓包时间太短，可重跑步骤2 并多
#   点击几个页面链接。
# ------------------------------------------------------------
