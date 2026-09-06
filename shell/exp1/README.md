# 实验1 脚本说明

对应指导书《实验1：Linux虚拟网络环境初探》各步骤的一键化脚本。
所有脚本需 **root/sudo** 执行，拓扑为：主机HA — 交换机SWA(网桥br-swa) — 主机HB，IPv4/IPv6 双协议栈。

## 脚本清单与执行顺序

| 顺序 | 脚本 | 对应步骤 | 作用 |
|---|---|---|---|
| 1 | `step1_check_env.sh` | 步骤1 环境检查 | 检查 root、iproute2、Wireshark、netns/veth/bridge 内核支持 |
| 2 | `step2_create_topology.sh` | 步骤2 创建拓扑 | 手动逐条命令版：netns + 网桥 + VETH + 绑定 |
| 3 | `step3_ipv4_test.sh` | 步骤3 IPv4 | 配 IPv4、tshark 抓包、ping 连通性测试 |
| 4 | `step4_ipv6_test.sh` | 步骤4 IPv6 | 配 IPv6 ULA、抓包、ping 连通性测试 |
| 5 | `step5_record_info.sh` | 步骤5(3) 记录 | 输出图1.2 要求记录的全部拓扑信息 |
| ★ | `create_topology.sh` | 步骤5 要求实现的脚本 | **一键 create / verify / destroy** |

## 快速开始（推荐路径）

```bash
cd shell/exp1
chmod +x *.sh

# 方式一：按步骤逐个执行（学习用）
sudo ./step1_check_env.sh
sudo ./step2_create_topology.sh
sudo ./step3_ipv4_test.sh
sudo ./step4_ipv6_test.sh
sudo ./step5_record_info.sh

# 方式二：一键自动化（步骤5 要求）
sudo ./create_topology.sh create
sudo ./create_topology.sh verify
# ...实验完成后
sudo ./create_topology.sh destroy
```

## 预期实验现象（汇总）

1. **步骤1**：root ✓、`ip -V` 输出版本、`wireshark --version` 输出版本、netns/veth/bridge 三项 ✓。
2. **步骤2**：`ip netns list` 出现 HA/HB/SWA；SWA 内出现 `br-swa`（up）；主空间出现 4 个 `ve-` 开头 VETH；迁移后各 NS 内接口正确；`bridge link show br-swa` 显示两个接口已绑定且 up。**此时未配 IP，ping 不通属正常。**
3. **步骤3**：接口显示 `inet 192.168.50.1/24`、`192.168.50.2/24`；ping 输出 `2 packets transmitted, 2 received, 0% packet loss`；pcap 中可见 **ARP 请求/应答 + ICMP Echo 请求/应答**。
4. **步骤4**：接口显示 `inet6 fd00::1:1/64`、`fd00::1:2/64`（另自动生成 fe80 链路本地地址）；ping 通；pcap 中可见 **ICMPv6 NDP（邻居请求/通告，替代 ARP）+ ICMPv6 Echo**。
5. **步骤5**：`create` 无报错；`verify` 列出全部命名空间/接口/网桥绑定/双栈地址，且两次 ping 打印 `IPv4 连通 ✓`、`IPv6 连通 ✓`；`destroy` 后系统恢复初始状态。
6. **记录脚本**：输出接口名、MAC、IP、VETH 对端对照表，可直接作为实验报告材料。

## 抓包说明

- 指导书使用 GUI Wireshark（`ip netns exec HA wireshark &`，选 `ve-ha-swa` 接口开始捕获）。
- 脚本内置等价的 **tshark 命令行抓包**，pcap 保存到 `/tmp/exp1_ipv4.pcap`、`/tmp/exp1_ipv6.pcap`，可拷回 Wireshark 图形界面分析（与 GUI 抓包结果一致）。

## 清理与重置

```bash
sudo ./create_topology.sh destroy   # 或手动: ip netns del HA && ip netns del HB && ip netns del SWA
```
