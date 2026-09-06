# 实验5 脚本说明

对应指导书《实验5：TCP可靠传输和重传分析》各步骤的一键化脚本。
拓扑与实验3/4**完全相同**（H56A—SW56A—RB—RA—RD—SW57C—H57C），核心内容：`tc netem` 随机丢包 + TCP 内核调参 + 100K 大文件传输 + 重传机制分析。

## 脚本清单与执行顺序

| 顺序 | 脚本 | 对应步骤 | 作用 |
|---|---|---|---|
| 1 | `step1_check_env.sh` | 步骤1 环境检查 | 工具检查（重点 **tc/sch_netem**）、关闭 firewalld |
| 2 | **`create_topology.sh`** | **步骤2（要求实现的脚本）** | 与实验3/4相同的一键拓扑（create/verify/destroy） |
| 3 | `step3_netem_loss.sh` | 步骤3 | RA 上挂载 netem 随机丢包（默认 10%，可调）+ ping 验证 |
| 4 | `step4_tcp_tuning.sh` | 步骤4(3)(4) | 两主机 `tcp_rmem='4096 65536 65536'` + `tcp_sack=0` |
| 5 | `step7_tcp_transfer.sh` | 步骤5/6/7 | H56A 建 100K 文件 + 抓包 + `ncat` 重定向传输 + 校验 |
| 6 | `step8_analyze_tcp.sh` | 步骤8 | 超时重传/快重传/重复ACK/部分ACK 识别与统计 |

> 步骤2(3)(4) 的拓扑记录与 offload 检查复用 `shell/exp3/step2_verify_offload.sh`。

## 快速开始

```bash
cd shell/exp5
chmod +x *.sh

sudo ./step1_check_env.sh
sudo ./create_topology.sh create
sudo ./create_topology.sh verify
sudo ./step3_netem_loss.sh 10          # RA 丢包 10%，可改 15/20
sudo ./step4_tcp_tuning.sh
sudo ./step7_tcp_transfer.sh           # -> /tmp/exp5_tcp.pcap
./step8_analyze_tcp.sh
sudo ./create_topology.sh destroy      # 同时清除 netem 规则
```

## 预期实验现象（汇总）

1. **步骤3**：`tc qdisc show` 输出 `qdisc netem ... loss 10%`；`ping -c 20` 丢包率在 0%~30% 波动（随机），对比实验3/4 的 0% 说明规则生效。首次清理旧规则报 `Cannot delete qdisc with handle of zero` 可忽略。
2. **步骤4**：`sysctl` 回读 `tcp_rmem = 4096 65536 65536`、`tcp_sack = 0`；后续 SYN 报文不再携带 SACK-permitted 选项。
3. **步骤7**：H57C 重定向文件最终 **102400 字节**，与源文件一致——10% 丢包下 TCP 依然可靠交付全部数据。
4. **步骤8 pcap 统计**：
   - **超时重传**：与原段相同 seq/len，间隔 ≥ RTO，触发后慢启动；
   - **快重传**：其前必有 ≥3 个重复 ACK，不等 RTO 立即重传，触发后快恢复；
   - **重复 ACK**：数量明显多于重传数（3 个触发 1 次快重传）；
   - **部分 ACK**：确认号落在已发数据中间，证明接收方中间缺段。

## 抓包不理想时的调整（指导书补充说明）

```bash
sudo ./step7_tcp_transfer.sh           # 重复实验直至抓到目标报文
sudo ./step3_netem_loss.sh 20          # 或提高丢包概率后重试
```

## 注意事项

- netem 作用于 **RA 出方向**（RA→RD），影响 H56A→H57C 数据流，方向正确才能触发回程 ACK 丢失/数据丢失两类场景。
- 10% 丢包下 100K 传输偶发较慢（连续丢包触发 RTO），脚本已设 120s 超时兜底。
- `tcp_rmem`/`tcp_sack` 仅在命名空间内生效，`destroy` 后随命名空间消失，不影响宿主机。
- 抓包在 **H56A 的 ve-H56A** 接口（本实验与实验3/4 不同，抓发送端），pcap 可拷回 GUI 分析。
