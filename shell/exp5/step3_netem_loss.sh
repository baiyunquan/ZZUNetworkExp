#!/usr/bin/env bash
# =============================================================
# 实验5 步骤3：配置路由器丢包规则，模拟网络异常
# 对应指导书《实验5》步骤3
# 用法: sudo ./step3_netem_loss.sh [丢包概率%，默认10]
# 说明: 在 RA 连接 RD 的 VETH 接口上挂载 netem，以指定概率随机丢包，
#       触发 TCP 重传机制。
# =============================================================
set -euo pipefail

NS_RA="RA"; NS_H56A="H56A"; NS_H57C="H57C"
IF_RA_RD="ve-RA-RD"          # RA 连接 RD 的接口（指导书示例 ve_RA_RD）
LOSS="${1:-10}"

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 sudo 执行" >&2; exit 1; }
ip netns list | grep -qw "$NS_RA" || { echo "[错误] 拓扑未创建，先运行 create_topology.sh create" >&2; exit 1; }

# 参数校验: 非法值直接报错，而不是让 tc 在 set -e 下报晦涩错误
if ! [[ "$LOSS" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk "BEGIN{exit !($LOSS > 0 && $LOSS <= 100)}"; then
    echo "[错误] 丢包概率必须是 0 < LOSS <= 100 的数值，当前为: $LOSS" >&2
    exit 1
fi

echo "==> 清理旧 qdisc 规则（从未添加过时报 Cannot delete... 错误，可忽略）"
ip netns exec "$NS_RA" tc qdisc del dev "$IF_RA_RD" root 2>/dev/null || \
    echo "    （无旧规则，忽略删除错误）"

echo "==> 挂载 netem: $IF_RA_RD 出方向报文以 ${LOSS}% 概率随机丢包"
ip netns exec "$NS_RA" tc qdisc add dev "$IF_RA_RD" root netem loss "${LOSS}%"
echo "==> 当前 qdisc 规则"
ip netns exec "$NS_RA" tc qdisc show dev "$IF_RA_RD"

echo "==> 验证: H56A ping H57C 20 个包，观察丢包率"
# ping 全丢时返回非零（iputils），pipefail 下会中止脚本——显式容错
if ! ip netns exec "$NS_H56A" ping -c 20 192.168.57.254 | tail -3; then
    echo "    [提示] ping 非零退出（20 个包可能全部丢失；仅在高丢包率下属预期）"
fi

# ------------------------------------------------------------
# 预期实验现象:
#   1. tc qdisc show 输出 "qdisc netem ... loss XX%"；
#   2. ping -c 20 的统计行显示丢包率在 0%~30% 之间波动（10% 概率
#      是随机的，20 个包样本小，实际丢 0~6 个都正常），
#      例如 "20 packets transmitted, 18 received, 10% packet loss"；
#      对比实验3/4 的 0% 丢包，说明丢包规则已生效。
#   3. 若 ping 丢包率长期为 0%，检查接口名是否正确（ip netns exec RA
#      ip link show 确认 ve-RA-RD 存在）、qdisc 是否挂在正确方向
#      （netem 作用于出方向，RA->RD 方向丢包影响 H56A->H57C 数据流）。
#   补充: 也可用 iptables 在用户态模拟丢包（指导书补充说明）。
# ------------------------------------------------------------
