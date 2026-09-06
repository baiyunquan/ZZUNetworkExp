#!/usr/bin/env bash
# =============================================================
# 实验3 步骤2(3)(4)：验证并记录拓扑信息 + offload 状态检查
# 对应指导书《实验3》步骤2 (3) 记录要求 与 (4) offload 验证
# 用法: sudo ./step2_verify_offload.sh
# 前置: 已执行 ./create_topology.sh create
# =============================================================
set -u

NS_H56A="H56A"; NS_H57C="H57C"; NS_RB="RB"; NS_RA="RA"; NS_RD="RD"
NS_SW56A="SW56A"; NS_SW57C="SW57C"

echo "================ 实验3 拓扑信息记录表 ================"
for ns in "$NS_H56A" "$NS_H57C" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW56A" "$NS_SW57C"; do
    echo ""
    echo "### 命名空间: $ns"
    # 注意: 必须用 ': lo:' 过滤（ip -o 输出格式是 "N: lo:"，" lo " 匹配不到）；
    #       ifname 必须剥掉 VETH 的 @peer 后缀，否则 ip addr show dev 会失败
    ip netns exec "$ns" ip -o link show 2>/dev/null | grep -vE ': lo:' | while IFS= read -r line; do
        ifname=$(echo "$line" | cut -d: -f2 | cut -d@ -f1 | tr -d ' ')
        mac=$(echo "$line" | grep -oE 'link/ether [0-9a-f:]+' | awk '{print $2}')
        echo "  接口: $ifname    MAC: ${mac:-无}"
        if ! ip netns exec "$ns" ip -o addr show dev "$ifname" 2>/dev/null \
            | grep -oE 'inet [0-9a-fA-F:./]+' | sed 's/^/    IP: /'; then
            echo "    IP: （未配置或查询失败）"
        fi
    done
done
cat <<'EOF'

### VETH 对端对照表
  H56A.ve-H56A      <---->  SW56A.ve-SW56A-H56A（接入 br_SW56A）
  RB.ve-RB-SW56A    <---->  SW56A.ve-SW56A-RB  （接入 br_SW56A）
  RB.ve-RB-RA       <---->  RA.ve-RA-RB        （192.168.56.244/30）
  RA.ve-RA-RD       <---->  RD.ve-RD-RA        （192.168.56.252/30）
  RD.ve-RD-SW57C    <---->  SW57C.ve-SW57C-RD  （接入 br_SW57C）
  H57C.ve-H57C      <---->  SW57C.ve-SW57C-H57C（接入 br_SW57C）
======================================================

==> offload 状态检查（要求 rx/tx-checksumming、generic-segmentation-offload 为 off）
EOF
check_offload() {
    local ns="$1" ifname="$2" bad=0
    echo "--- $ns.$ifname ---"
    # 命名空间/接口不存在时报错而非静默输出空表
    if ! ip netns exec "$ns" ethtool -k "$ifname" 2>/dev/null > /tmp/.exp3_offload.$$; then
        echo "    [错误] 无法读取 $ns.$ifname 的 offload 状态（拓扑未创建或 ethtool 未安装）" >&2
        rm -f /tmp/.exp3_offload.$$
        return 1
    fi
    while IFS= read -r l; do
        echo "    $l"
        case "$l" in *": on") bad=1 ;; esac
    done < <(grep -E "^(rx-checksumming|tx-checksumming|generic-segmentation-offload|generic-receive-offload)" /tmp/.exp3_offload.$$)
    rm -f /tmp/.exp3_offload.$$
    if [ "$bad" -eq 1 ]; then
        echo "    [失败] $ns.$ifname 存在未关闭的 offload ✗" >&2
        return 1
    fi
    return 0
}
VERIFY_FAIL=0
check_offload "$NS_H56A" "$V_H56A"      || VERIFY_FAIL=1
check_offload "$NS_H57C" "$V_H57C"      || VERIFY_FAIL=1
check_offload "$NS_RB"   "ve-RB-SW56A"  || VERIFY_FAIL=1
check_offload "$NS_RB"   "ve-RB-RA"     || VERIFY_FAIL=1
check_offload "$NS_RA"   "ve-RA-RB"     || VERIFY_FAIL=1
check_offload "$NS_RA"   "ve-RA-RD"     || VERIFY_FAIL=1
check_offload "$NS_RD"   "ve-RD-RA"     || VERIFY_FAIL=1
check_offload "$NS_RD"   "ve-RD-SW57C"  || VERIFY_FAIL=1

if [ "$VERIFY_FAIL" -eq 0 ]; then
    echo "==> offload 检查全部通过 ✓"
else
    echo "==> offload 检查存在失败项，校验和分析结果将不可信 ✗" >&2
    exit 1
fi

# ------------------------------------------------------------
# 预期实验现象:
#   1. 记录表列出每个命名空间的接口名、MAC、IP，与 create_topology.sh
#      的规划一一对应，可直接作为实验报告的拓扑记录材料；
#   2. offload 检查中，所有主机/路由器 VETH 网卡的
#      rx-checksumming: off、tx-checksumming: off、
#      generic-segmentation-offload: off、generic-receive-offload: off；
#      若某项仍为 on，说明 create 脚本的 offload_off 未生效，
#      需检查 ethtool 是否安装、接口名是否正确。
#   意义: 关闭 offload 后，UDP 校验和计算、IP 分片均由 CPU 完成，
#   Wireshark 抓到的报文才能真实反映协议栈行为（否则会看到
#   checksum incorrect 的"伪错误"或超长段不被分片）。
# ------------------------------------------------------------
