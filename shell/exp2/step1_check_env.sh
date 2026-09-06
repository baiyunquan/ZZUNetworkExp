#!/usr/bin/env bash
# =============================================================
# 实验2 步骤1：环境检查
# 对应指导书《实验2》步骤1 (1)-(4)
# 用法: ./step1_check_env.sh   （无需 root）
# =============================================================
set -u
SITE="www.zzu.edu.cn"

echo "==> (1) 用户权限"
[ "$(id -u)" -eq 0 ] && echo "    root 用户 ✓" || echo "    普通用户（本实验抓包需 sudo，浏览器/抓包需同一会话）"

echo "==> (2) 软件工具"
ip -V || { echo "    [错误] ip 不可用" >&2; exit 1; }
wireshark --version 2>/dev/null | head -1 || echo "    [警告] Wireshark 未安装"
command -v tshark >/dev/null && echo "    tshark ✓（命令行抓包/分析）" || echo "    [警告] tshark 未安装"

echo "==> (3) 浏览器"
command -v firefox >/dev/null && firefox --version 2>/dev/null || echo "    [警告] Firefox 未安装（实验2必需，用于导出 TLS 密钥日志）"

echo "==> (4) DNS 解析与协议优先级检查（$SITE）"
if command -v getent >/dev/null; then
    echo "    A    记录(IPv4): $(getent ahostsv4 "$SITE" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    echo "    AAAA 记录(IPv6): $(getent ahostsv6 "$SITE" | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi
echo "    完整对应关系以 Firefox about:networking#dnslookuptool 查询结果为准（结果在前者优先使用该协议）"

echo "==> (5) 公网连通性测试"
IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}')
echo "    默认出口接口: ${IFACE:-未知}（Wireshark 抓包选它）"
curl -4 -sI -m 10 "https://$SITE" | head -1 && echo "    IPv4 HTTPS 可达 ✓" || echo "    IPv4 HTTPS 不可达 ✗"
curl -6 -sI -m 10 "https://$SITE" | head -1 && echo "    IPv6 HTTPS 可达 ✓" || echo "    IPv6 HTTPS 不可达（仅 IPv4 单栈环境，属正常）"

# ------------------------------------------------------------
# 预期实验现象:
#   (2)(3) ip -V、Wireshark/tshark、Firefox 均输出版本号，安装正常；
#   (4) $SITE 解析出 2 个 IPv4（如 202.196.64.194 / 202.196.64.48）和
#       2 个 IPv6（如 2001:da8:5000:6c00::48 / ::47）地址，
#       说明服务器同时配置 A + AAAA 记录，支持双栈访问；
#      Firefox 中 about:networking#dnslookuptool 查询结果排在前面的
#       协议即为浏览器优先使用的协议（IPv4 在前优先 IPv4，反之优先 IPv6）；
#   (5) IPv4 HTTPS 返回 "HTTP/2 200"（或 301/302）表示可达；
#      IPv6 视本机网络而定，不支持时显示不可达，即为"IPv4 单栈场景"。
#   记录: 默认出口接口名（如 eth0/wlan0/ens33），后续抓包要用。
# ------------------------------------------------------------
