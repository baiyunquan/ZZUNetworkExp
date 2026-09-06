#!/usr/bin/env bash
# =============================================================
# 实验 GUI 自动化截图工具
# 用途: 程序控制图形界面（Wireshark/Firefox/终端）并自动截图，
#       产出与指导书一致的实验核验截图，无需人工操作。
#
# 依赖: spectacle(KDE 截图) + xdotool(窗口自动化)，本机均已安装
#
# 子命令:
#   ./screenshot_toolkit.sh wireshark <pcap> <显示过滤器> <输出.png>
#       打开 Wireshark 加载 pcap、应用显示过滤器、自动截图
#       示例: ./screenshot_toolkit.sh wireshark /tmp/exp4_tcp.pcap \
#             "tcp.flags.syn==1" exp4_handshake.png
#
#   ./screenshot_toolkit.sh firefox <url> <输出.png> [等待秒数]
#       打开 Firefox 访问页面、等待加载、自动截图
#       示例: ./screenshot_toolkit.sh firefox \
#             "about:networking#dnslookuptool" exp2_dns.png 5
#
#   ./screenshot_toolkit.sh term <命令...> <输出.png>
#       打开新终端窗口执行命令、等待、自动截图
#       示例: ./screenshot_toolkit.sh term \
#             "tshark -r /tmp/exp5_tcp.pcap -Y 'tcp.analysis.retransmission'" \
#             exp5_retrans.png
# =============================================================
set -uo pipefail

SHOT() {  # 静默后台截图（全屏）
    spectacle -b -n -f -o "$1" >/dev/null 2>&1
    sleep 1
    [ -s "$1" ] && echo "    [截图] $1" || { echo "    [错误] 截图失败" >&2; return 1; }
}

# Wayland 下激活窗口: KWin 脚本（xdotool 对 wayland 原生窗口无效）
kwin_activate() {  # $1=窗口标题包含的关键字
    local kw="$1" js=/tmp/.kwin_raise.js
    cat > "$js" <<EOF
for (const w of workspace.windowList()) {
    if (w.caption && w.caption.indexOf("$kw") !== -1) {
        workspace.activeWindow = w;
        break;
    }
}
EOF
    busctl --user call org.kde.KWin /Scripting \
        org.kde.kwin.Scripting loadScript s "$js" >/dev/null
    busctl --user call org.kde.KWin /Scripting \
        org.kde.kwin.Scripting start >/dev/null
    sleep 1
}

cmd_wireshark() {
    local pcap="$1" filter="$2" out="$3"
    command -v wireshark >/dev/null || { echo "[错误] wireshark 未安装" >&2; return 1; }
    echo "==> 打开 Wireshark 加载 $pcap"
    wireshark -r "$pcap" >/dev/null 2>&1 &
    sleep 5
    kwin_activate "Wireshark"
    echo "==> 应用显示过滤器: $filter （KDE Wayland 下若未生效，请手动 Alt+D 输入）"
    # 尝试 Xwayland 键盘注入；wayland 原生窗口需安装 wtype 后改用 wtype
    local win
    win=$(xdotool search --name "Wireshark" 2>/dev/null | head -1)
    if [ -n "$win" ]; then
        xdotool key --window "$win" alt+d 2>/dev/null || xdotool key ctrl+l
        sleep 1
        xdotool type --delay 30 "$filter"
        xdotool key Return
        sleep 3
    fi
    SHOT "$out"
    echo "==> 完成（Wireshark 窗口保持打开，可人工检查后关闭）"
}

cmd_firefox() {
    local url="$1" out="$2" wait="${3:-5}"
    command -v firefox >/dev/null || { echo "[错误] firefox 未安装" >&2; return 1; }
    echo "==> 独立实例打开 Firefox: $url"
    # --no-remote + 独立 profile: 不受已运行实例影响，且能读到 SSLKEYLOGFILE
    firefox --no-remote -profile /tmp/.ff-shot "$url" >/dev/null 2>&1 &
    sleep "$wait"
    kwin_activate "Firefox"
    SHOT "$out"
    pkill -f "\-profile /tmp/.ff-shot" 2>/dev/null
    rm -rf /tmp/.ff-shot
}

cmd_term() {
    local out="${@: -1}"; local cmd="${*:1:$#-1}"
    echo "==> 打开终端执行: $cmd"
    if command -v konsole >/dev/null; then
        konsole -e bash -c "$cmd; echo 按回车关闭; read" >/dev/null 2>&1 &
    elif command -v gnome-terminal >/dev/null; then
        gnome-terminal -- bash -c "$cmd; echo 按回车关闭; read" >/dev/null 2>&1 &
    else
        echo "[错误] 未找到 konsole/gnome-terminal" >&2; return 1
    fi
    sleep 4
    SHOT "$out"
}

case "${1:-}" in
    wireshark) shift; cmd_wireshark "$@" ;;
    firefox)   shift; cmd_firefox "$@" ;;
    term)      shift; cmd_term "$@" ;;
    *) grep '^#   \./' "$0" | sed 's/^#   //'; echo; echo "用法: $0 {wireshark|firefox|term} ...";;
esac
