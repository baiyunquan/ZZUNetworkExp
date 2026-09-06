#!/usr/bin/env bash
# =============================================================
# 实验1 步骤5(3)：验证并记录拓扑信息（对应图1.2 要求的记录项）
# 记录: 命名空间名称 / NS内VETH接口名 / IP地址 / MAC地址 /
#       对端接口名称及所属NS
# 用法: sudo ./step5_record_info.sh
# =============================================================
set -u

NS_HA="HA"; NS_HB="HB"; NS_SWA="SWA"

echo "================ 实验1 拓扑信息记录表 ================"

for ns in "$NS_HA" "$NS_HB" "$NS_SWA"; do
    echo ""
    echo "### 命名空间: $ns"
    ip netns exec "$ns" ip -o link show 2>/dev/null | grep -v ': lo:' | while IFS= read -r line; do
        ifname=$(echo "$line" | cut -d: -f2 | tr -d ' ')
        mac=$(echo "$line" | grep -oE 'link/ether [0-9a-f:]+' | awk '{print $2}')
        peer=$(echo "$line" | sed -n 's/.*@if\([0-9]\+\).*/\1/p')
        echo "  接口: $ifname"
        echo "    MAC 地址: ${mac:-无（网桥/未配）}"
        if [ -n "$peer" ]; then
            echo "    对端接口索引: if$peer（对端位于另一命名空间，见下方对照）"
        fi
        ip netns exec "$ns" ip -o addr show dev "$ifname" 2>/dev/null | grep -oE 'inet6? [0-9a-fA-F:./]+' \
            | sed 's/^/    IP 地址: /'
    done
done

echo ""
echo "### VETH 对端对照表（由创建时的命名决定）"
cat <<EOF
  VETH 对 1: HA.ve-ha-swa  <---->  SWA.ve-swa-ha（接入网桥 br-swa）
  VETH 对 2: HB.ve-hb-swa  <---->  SWA.ve-swa-hb（接入网桥 br-swa）
EOF

echo ""
echo "### 连通性验证"
ip netns exec "$NS_HA" ping -c 2 192.168.50.2  >/dev/null 2>&1 && echo "  HA -> HB (IPv4) 通 ✓" || echo "  HA -> HB (IPv4) 不通 ✗"
ip netns exec "$NS_HA" ping -c 2 fd00::1:2     >/dev/null 2>&1 && echo "  HA -> HB (IPv6) 通 ✓" || echo "  HA -> HB (IPv6) 不通 ✗"

echo "======================================================"

# ------------------------------------------------------------
# 预期实验现象:
#   1. 每个命名空间下列出接口名、MAC 地址、IP 地址（IPv4 + IPv6 全局 +
#      fe80 链路本地），与图1.2 要求记录的信息一一对应；
#   2. 对照表明确给出两对 VETH 的两端接口及所属命名空间；
#   3. 连通性验证输出两行 "通 ✓"。
#   将本脚本输出截图或复制保存，即为实验报告所需的拓扑记录材料。
#   参考值（与指导书图1.2 一致）:
#     HA.ve-ha-swa  MAC 形如 82:eb:13:d6:dd:6e，IP 192.168.50.1/24、fd00::1:1/64
#     HB.ve-hb-swa  MAC 随机生成，            IP 192.168.50.2/24、fd00::1:2/64
#     SWA.ve-swa-ha / ve-swa-hb 无 IP（交换机侧接口不配地址）
# ------------------------------------------------------------
