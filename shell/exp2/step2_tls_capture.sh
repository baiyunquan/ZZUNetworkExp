#!/usr/bin/env bash
# =============================================================
# 实验2 步骤2（核心自动化脚本）：TLS 密钥日志 + HTTPS 抓包
# 对应指导书《实验2》步骤2 (1)-(5)
# 用法: sudo ./step2_tls_capture.sh [访问秒数，默认15]
# 流程: export SSLKEYLOGFILE -> 启动 Firefox(独立实例) -> tshark 抓包
#       -> 访问 https://www.zzu.edu.cn -> 停止抓包 -> 校验密钥日志
# 说明: 指导书用 GUI Wireshark 手动配置 TLS 密钥文件（首选项->Protocols
#       ->TLS->(Pre)-Master-Secret log filename）；本脚本用 tshark 的
#       tls.keylog_file 选项实现等价自动解密，并保留 pcap+keylog 供
#       GUI Wireshark 复现。
# =============================================================
set -euo pipefail

SITE="www.zzu.edu.cn"
WAIT="${1:-15}"
OUT_DIR="$(pwd)"
KEYLOG="$OUT_DIR/myssl.log"
PCAP="$OUT_DIR/exp2_https.pcap"
FF_PROFILE="/tmp/ff-exp2-profile"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行（抓包需要权限）" >&2; exit 1; }
command -v firefox >/dev/null || { echo "[错误] 未安装 firefox" >&2; exit 1; }
command -v tshark  >/dev/null || { echo "[错误] 未安装 tshark" >&2; exit 1; }

IFACE=$(ip route get 1.1.1.1 | grep -oE 'dev [^ ]+' | awk '{print $2}')
echo "==> 抓包接口: $IFACE"

echo "==> (1) 配置 TLS 会话密钥日志环境变量"
export SSLKEYLOGFILE="$KEYLOG"
rm -f "$KEYLOG" "$PCAP"
echo "    SSLKEYLOGFILE=$SSLKEYLOGFILE"

echo "==> (2) 后台启动 Firefox（独立实例，确保读取 SSLKEYLOGFILE）"
rm -rf "$FF_PROFILE"
firefox --no-remote -profile "$FF_PROFILE" "https://$SITE" >/dev/null 2>&1 &
FF_PID=$!
sleep 5

echo "==> (3) 启动 tshark 抓包（等价于 GUI Wireshark 开始捕获）"
tshark -i "$IFACE" -w "$PCAP" >/dev/null 2>&1 &
TS_PID=$!
sleep 2

echo "==> (4) 等待 ${WAIT}s 让页面完全加载（如未弹出可手动在 Firefox 中操作）"
sleep "$WAIT"

echo "==> (5) 停止抓包并校验"
kill "$TS_PID" 2>/dev/null || true; wait "$TS_PID" 2>/dev/null || true
kill "$FF_PID" 2>/dev/null || true

if [ -s "$KEYLOG" ]; then
    echo "    密钥日志已生成: $KEYLOG ($(wc -l < "$KEYLOG") 行)"
else
    echo "    [警告] 密钥日志为空！请确认 Firefox 是本脚本启动的新实例" >&2
fi
ls -l "$PCAP"

echo "==> (6) 用密钥日志解密 TLS，验证能看到明文 HTTP（等价 GUI 配置后的效果）"
tshark -r "$PCAP" -o "tls.keylog_file:$KEYLOG" -Y "http.request || http.response" \
    -T fields -e frame.number -e ip.dst -e ipv6.dst -e http.host -e http.request.method 2>/dev/null \
    | head -10 || true

# ------------------------------------------------------------
# 预期实验现象:
#   (2) Firefox 窗口弹出并加载 $SITE 首页；
#   (5) myssl.log 生成且非空（每行一条 TLS 密钥记录，形如
#       "CLIENT_HANDSHAKE_TRAFFIC_SECRET xxxx ..."），pcap 文件生成；
#   (6) tshark 解密后列出若干 HTTP 请求行，含 http.host=www.zzu.edu.cn、
#       http.request.method=GET 等 —— 说明 TLS 解密成功，
#       等价于指导书中"配置密钥日志后 Wireshark 自动展示明文"的现象。
#   GUI 复现方法（对应指导书）:
#     Wireshark 打开 exp2_https.pcap -> 编辑->首选项->Protocols->TLS->
#     (Pre)-Master-Secret log filename 选 myssl.log -> OK，
#     报文列表中 TLS 条目即变为可展开的 HTTP 明文。
#   若密钥日志为空: 先关闭已运行的 Firefox 再重跑（旧实例不读新环境变量）。
# ------------------------------------------------------------
