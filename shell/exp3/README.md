# 实验3 脚本说明

对应指导书《实验3：UDP协议探索与分析》各步骤的一键化脚本。
拓扑：主机H56A — 交换机SW56A — 路由器RB — 路由器RA — 路由器RD — 交换机SW57C — 主机H57C（2主机+2交换机+3路由器），跨三跳路由的 UDP 通信。

## 脚本清单与执行顺序

| 顺序 | 脚本 | 对应步骤 | 作用 |
|---|---|---|---|
| 1 | `step1_check_env.sh` | 步骤1 环境检查 | root、iproute2/ncat/traceroute/ethtool/Wireshark、关闭 firewalld |
| 2 | **`create_topology.sh`** | **步骤2（要求实现的脚本）** | 一键 `create`/`verify`/`destroy`：7 命名空间 + 2 网桥 + 6 对 VETH + IP/静态路由 + ip_forward + 关 offload |
| 3 | `step2_verify_offload.sh` | 步骤2(3)(4) | 输出拓扑记录表（图1.2 同款）+ offload 状态检查 |
| 4 | `step3_udp_comm.sh` | 步骤3/4/5 | 模拟主机终端 + H57C 抓包 + ncat UDP 双向通信（自动化） |
| 5 | `step4_analyze_udp.sh` | 步骤6 报文分析 | 筛选 UDP、提取首部字段、结构解读、校验和验证 |

## 快速开始

```bash
cd shell/exp3
chmod +x *.sh

sudo ./step1_check_env.sh
sudo ./create_topology.sh create
sudo ./create_topology.sh verify        # ping 4 包全通 + traceroute 3 跳
sudo ./step2_verify_offload.sh          # offload 全部 off
sudo ./step3_udp_comm.sh                # UDP 双向通信 + 抓包 -> /tmp/exp3_udp.pcap
./step4_analyze_udp.sh                  # UDP 首部分析
sudo ./create_topology.sh destroy       # 实验完清理
```

## IP 规划（指导书固定地址）

| 节点/链路 | 地址 |
|---|---|
| H56A | 192.168.56.126/25（网关 192.168.56.1） |
| RB—SW56A 侧 | 192.168.56.1/25 |
| RB—RA 互连 | 192.168.56.245/30 ↔ 192.168.56.246/30 |
| RA—RD 互连 | 192.168.56.253/30 ↔ 192.168.56.254/30 |
| RD—SW57C 侧 | 192.168.57.193/26 |
| H57C | 192.168.57.254/26（网关 192.168.57.193） |

## 预期实验现象（汇总）

1. **步骤1**：全部工具 ✓，firewalld 关闭（否则 UDP 报文可能被丢弃）。
2. **步骤2 verify**：7 个命名空间；两网桥各绑 2 接口；三路由器 `ip_forward=1`；`ping -c 4 192.168.57.254` → `4 received, 0% packet loss`；`traceroute` 输出 3 跳：`192.168.56.1(RB) → 192.168.56.246(RA) → 192.168.57.254(H57C)`。
3. **offload 检查**：所有 VETH 的 rx/tx-checksumming、gso/gro 均为 **off**（保证校验和/分片由 CPU 计算，Wireshark 才能验证真实校验和）。
4. **步骤5 UDP 通信**：客户端发送一行字符，服务端回显，客户端收到相同内容——双向通信成功；pcap 中**无握手/确认报文**（对比 TCP），源/目的端口 4499 ↔ 临时端口。
5. **步骤6 分析**：UDP 首部仅 8 字节（源端口/目的端口/长度/校验和各 2 字节）；`udp.checksum.status` 统计为 good。

## 交互式操作（对应指导书原始步骤3/5）

```bash
# 终端1（标题 H57C）
sudo ip netns exec H57C bash
ncat -lvu 4499

# 终端2（标题 H56A）
sudo ip netns exec H56A bash
ncat -u 192.168.57.254 4499
# 两边交替输入字符回车即可双向收发；exit 退出模拟终端
```

## 注意事项

- `ncat` 属 `nmap` 包；`ethtool` 需单独安装（offload 检查必需）。
- 若 ping 通但 ncat 不通，优先检查 firewalld 是否关闭。
- 抓包用 tshark 等价 GUI Wireshark（`ip netns exec H57C wireshark &` 选 `ve-H57C` 接口），pcap 可拷回 GUI 分析。
