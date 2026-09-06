# 实验4 脚本说明

对应指导书《实验4：TCP协议探索与连接管理分析》各步骤的一键化脚本。
拓扑与实验3**完全相同**（H56A—SW56A—RB—RA—RD—SW57C—H57C），核心内容是 TCP 远程 shell 文件传输与连接管理（三次握手/四次挥手）分析。

## 脚本清单与执行顺序

| 顺序 | 脚本 | 对应步骤 | 作用 |
|---|---|---|---|
| 1 | `step1_check_env.sh` | 步骤1 环境检查 | 工具检查（含 **truncate**）、关闭 firewalld |
| 2 | **`create_topology.sh`** | **步骤2（要求实现的脚本）** | 与实验3相同的一键拓扑（create/verify/destroy） |
| 3 | `step4_create_testfile.sh` | 步骤4 | H57C 上 `truncate -s 3500 3500.dat` 创建测试文件 |
| 4 | `step6_tcp_file_transfer.sh` | 步骤5/6 | 抓包 + `ncat -e /bin/sh` 远程 shell + 跨网络文件传输（自动化） |
| 5 | `step7_analyze_tcp.sh` | 步骤7 | 三次握手/数据分段/四次挥手/首部字段分析 |

> 步骤2(3)(4) 的拓扑记录与 offload 检查与实验3完全一致，可直接复用
> `shell/exp3/step2_verify_offload.sh`（注意：**每次重建拓扑 MAC 会变**，需重新记录；
> 该脚本标题固定为"实验3 拓扑信息记录表"，用于实验4报告时注意改名）。

## 快速开始

```bash
cd shell/exp4
chmod +x *.sh

sudo ./step1_check_env.sh
sudo ./create_topology.sh create
sudo ./create_topology.sh verify
sudo ./step4_create_testfile.sh
sudo ./step6_tcp_file_transfer.sh      # -> /tmp/exp4_tcp.pcap + /tmp/exp4_received.dat
./step7_analyze_tcp.sh
sudo ./create_topology.sh destroy
```

## 预期实验现象（汇总）

1. **步骤4**：`ls -l` 显示 `/root/3500.dat` 恰为 3500 字节（全 0 稀疏文件，仅作载荷）。
2. **步骤6**：
   - 服务端输出 `Listening on 0.0.0.0:4499`；
   - 客户端发送 `cat /root/3500.dat` → 文件内容经 TCP 回传，客户端收到 **3500 字节** → 传输成功（大小不符时脚本以非零退出码报错）；
   - 服务端 shell 执行 `exit` 正常退出 → 服务端先发 FIN，连接按四次挥手优雅释放（若进程被信号强杀则产生 RST，pcap 中将看不到挥手）。
3. **步骤7 pcap 分析**：
   - **三次握手**：`SYN(seq=x) → SYN,ACK(seq=y,ack=x+1) → ACK(seq=x+1,ack=y+1)`，SYN 携带 **MSS 选项**（通常 1460）与**窗口扩大选项**；
   - **数据传输**：H57C→H56A 约 3 个数据段合计 3500 字节（1460+1460+580，每段 ≤MSS），序号逐段递增，确认号=期望的下一字节；
   - **四次挥手**：`FIN,ACK → ACK → FIN,ACK → ACK`（中间常合并为 3 条报文，属正常）。

## 交互式操作（对应指导书原始步骤3/6）

```bash
# 终端1（标题 H57C）
sudo ip netns exec H57C bash
truncate -s 3500 3500.dat
ncat -e /bin/sh -lv 4499

# 终端2（标题 H56A）
sudo ip netns exec H56A bash
ncat 192.168.57.254 4499
cat 3500.dat        # 回车，文件内容回传到本终端
# 传输完毕: 先在 H57C 按 Ctrl+C，再在 H56A 按 Ctrl+C，观察连接释放
```

## 注意事项

- `ncat -e /bin/sh` 是远程 shell（实验用途），实验结束务必 `destroy` 清理。
- 3500 字节 > MSS(1460)，必然产生多段传输，便于观察 TCP 分段与累积确认。
- 抓包用 tshark 等价 GUI Wireshark（`ip netns exec H57C wireshark &` 选 `ve-H57C`），pcap 可拷回 GUI 分析。
