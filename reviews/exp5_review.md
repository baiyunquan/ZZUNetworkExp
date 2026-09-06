# 实验5 脚本审查报告

> 审查者：subagent（OpenCode Go / Glm 5.3 Flash）· 2026-09-06
> 审查范围：`shell/exp5/` 全部脚本 + `README.md`，对照 `instruction/05_实验5.md`（只读审查，未修改任何文件）

## 🔴 确认的 Bug

### 1. `shell/exp5/step8_analyze_tcp.sh` — `tshark | head -10` 在 `set -euo pipefail` 下会因 SIGPIPE 中断整个脚本
- **行号**：第 13–15、17–18、33–34 行（三处），配合脚本第 4 行的 `set -euo pipefail`
- **问题原文**：
  ```bash
  tshark -r "$PCAP" -Y "tcp.analysis.retransmission && !tcp.analysis.fast_retransmission" -T fields \
      -e frame.number -e ip.src -e tcp.seq -e tcp.ack -e tcp.len 2>/dev/null | head -10
  ```
- **为什么错**：10% 丢包下传 100K（约 70 段）时重传/重复 ACK 数量很容易超过 10 条。`head -10` 读满即退出，tshark 随后写入收到 SIGPIPE，pipeline 退出码为 141；`pipefail` 使整个管道返回非零，`set -e` 立即终止脚本。结果是**第 (2) 统计、(3) 部分 ACK、(4) 解读全部不会执行**——重复 ACK 数量几乎必然超过 10，即使第 (1) 节侥幸通过，第 (3) 节也会触发同样问题。这是与实验1同类"`set -e` 与命令交互"缺陷的变体。
- **修复建议**：去掉 `head -10`，改为 `tshark ... | sed -n '1,10p'`（sed 会持续消费输入不触发 SIGPIPE），或 `tshark ... -c 10` 直接限制输出，或管道尾用 `|| true` 兜底。

### 2. `shell/exp5/step8_analyze_tcp.sh` — "(3) 部分 ACK 抽样"的过滤器根本无法识别部分 ACK
- **行号**：第 32–34 行
- **问题原文**：
  ```bash
  tshark -r "$PCAP" -Y "tcp.analysis.duplicate_ack || tcp.analysis.retransmission" -T fields ...
  ```
- **为什么错**：该过滤器选出的报文是**重复 ACK 和重传报文**，与部分 ACK 毫无对应关系。部分 ACK 是普通 ACK 报文（tshark 没有现成的 `tcp.analysis` 标志），特征是其确认号推进量小于 outstanding 数据量，无法用一个 display filter 直接筛出。当前输出会打印重传段的 `tcp.ack`，并冠以"确认号未推进到最新已发数据"的标题，误导实验者把重复 ACK 当成部分 ACK 写进报告。该节的文字说明（"部分 ACK 抽样"）与实际输出完全不符。
- **修复建议**：本节应改为演示型分析，例如先用 `tshark -Y "tcp.analysis.retransmission"` 找到丢失段序号 X，再展示其后第一个 ACK 确认号介于 X 与最新 seq 之间的报文；或至少改标题为"丢失段前后 ACK 序列观察"，避免错误标注。

### 3. `shell/exp5/create_topology.sh` — `bridge link show` 缺少 `dev` 关键字，参数被静默忽略（实验1同类问题）
- **行号**：第 116–117 行
- **问题原文**：
  ```bash
  ip netns exec "$NS_SW56A" bridge link show "$BR_56A"
  ip netns exec "$NS_SW57C" bridge link show "$BR_57C"
  ```
- **为什么错**：`bridge link show` 只接受 `dev IFNAME` 形式，裸位置参数被静默忽略。我在本机实测确认：`bridge link show lo` 输出的是**全部网桥端口**（非 lo 相关），退出码 0。此外语义也错——`bridge link show` 显示的是网桥的 slave 端口，传网桥设备名 `br_SW56A` 本身就不对；即使加了 `dev br_SW56A` 也只会输出空。verify 因此打印的是"该 NS 内所有端口列表"，看起来正常但从未验证过目标网桥绑定，属于摆设式检查。
- **修复建议**：改为 `ip netns exec "$NS_SW56A" bridge link show dev ve-SW56A-H56A; ... dev ve-SW56A-RB`，或用 `ip netns exec "$NS_SW56A" ip link show master "$BR_56A"`。

### 4. `shell/exp5/create_topology.sh` — create 不幂等、无回滚，明显落后于实验1已修复的实现
- **行号**：第 39–48 行（`ip netns add` 循环）及整个 `do_create`
- **问题原文**：
  ```bash
  for ns in "$NS_H56A" "$NS_SW56A" "$NS_RB" "$NS_RA" "$NS_RD" "$NS_SW57C" "$NS_H57C"; do
      ip netns add "$ns"
  done
  ```
- **为什么错**：重复执行 `create` 时第一条 `ip netns add H56A` 即报 "File exists" 并因 `set -e` 中止（`do_create` 里既无先销毁逻辑，也无 exp1 那样的 ERR trap 回滚）。更糟的是：**若在创建中途失败**（如某条 `ip link add` 失败），会留下半成品拓扑（部分命名空间、部分 VETH），下次 create 仍失败，用户必须手工 destroy。对比 `shell/exp1/create_topology.sh` 已实现的"检测到旧拓扑先 destroy + `trap ... ERR` 回滚"，这是同一系列里的实现倒退。README"快速开始"也没有说明重复 create 前要先 destroy。
- **修复建议**：移植 exp1 的 `ns_exists` 检测 + 先销毁 + ERR 回滚逻辑。

## 🟠 明显缺陷

### 5. `shell/exp5/step8_analyze_tcp.sh` 第 22 行 — "超时重传"统计把伪重传（spurious）也计入
- **问题原文**：`RTO=$(tshark -r "$PCAP" -Y "tcp.analysis.retransmission && !tcp.analysis.fast_retransmission" ... | wc -l)`，而第 25 行又单独统计 `tcp.analysis.spurious_retransmission`。
- **为什么错**：Wireshark 中 spurious retransmission 同时会置 `tcp.analysis.retransmission` 标志，所以伪重传被**双重计入**：既出现在"超时重传"计数里又出现在"伪重传"计数里，两者之和会大于实际重传总数，与 (1) 节展示的明细也对不上。
- **修复建议**：过滤器追加 `&& !tcp.analysis.spurious_retransmission`。

### 6. `shell/exp5/step7_tcp_transfer.sh` 第 28–29 行 — tshark 错误被完全吞掉，抓包失败会静默产生空 pcap
- **问题原文**：
  ```bash
  ip netns exec "$NS_H56A" tshark -i "$IF_H56A" -w "$PCAP" >/dev/null 2>&1 &
  TS_PID=$!
  ```
- **为什么错**：`$!` 只是启动了后台进程，脚本从不检查 tshark 是否真的活着。若 `PCAP_DIR` 不存在（第 15 行允许用户传入任意目录）、或 `ve-H56A` 名字与实际不符，tshark 立刻退出但 stderr 被丢弃，脚本继续完成"传输 + 校验"，最后 `ls -l` 一个不存在的 pcap 或 0 字节 pcap，step8 分析时才发现抓包为空。这是"pcap 截断/空抓包"类的典型缺陷。
- **修复建议**：启动后 `sleep` 后用 `kill -0 "$TS_PID"` 探活；启动前 `mkdir -p "$PCAP_DIR"`；错误输出重定向到日志文件而非 `/dev/null`。

### 7. `shell/exp5/step3_netem_loss.sh` 第 28 行 — `ping | tail -3` 在高丢包率下会因 pipefail 中止脚本
- **问题原文**：`ip netns exec "$NS_H56A" ping -c 20 192.168.57.254 | tail -3`
- **为什么错**：ping 在 20 个包全部超时时返回非零（iputils ping：有应答返回 0，无应答返回 1）。`set -euo pipefail` 下执行 `./step3_netem_loss.sh 100`（或 90 以上极端值）ping 若全丢，脚本在打印完统计行后以非零退出，报错信息具有误导性。10% 默认值下几乎不会触发，但脚本明确允许传参调整丢包率（README 建议改 15/20）。
- **修复建议**：改为 `ip netns exec "$NS_H56A" ping -c 20 192.168.57.254 | tail -3 || echo "    [提示] ping 非零退出（可能全丢包）"`，或先 `set +e` 包裹。

### 8. `shell/exp5/README.md` — 关于 netem 丢包方向的说明与事实不符
- **行号**："注意事项"节：*"netem 作用于 RA 出方向（RA→RD），影响 H56A→H57C 数据流，方向正确才能触发回程 ACK 丢失/数据丢失两类场景。"*
- **为什么错**：netem 挂在 `ve-RA-RD` 上只影响 RA→RD 出方向，即只有 H56A→H57C 的**数据段**会丢；H57C→H56A 的 ACK 在 RA 上从 `ve-RA-RB` 出方向转发，不受影响。实验只会出现"数据丢失"场景，"回程 ACK 丢失"永远不会被模拟。指导书本身即指定此接口（与指导书一致），但 README 的这句话会让读者误以为两个方向都受影响，进而在抓包分析时误判 ACK 丢失现象。
- **修复建议**：更正为"仅模拟去程数据段丢失；如需模拟 ACK 丢失，需另在 `ve-RA-RB` 上挂 netem"。

### 9. `shell/exp5/create_topology.sh` 第 3 行 — 头注释仍是"实验4"，复制粘贴残留
- **问题原文**：`# 实验4 步骤2（要求实现的脚本）：一键创建/验证/销毁实验4拓扑`、`# 对应指导书《实验4》步骤2 ...`
- **为什么错**：文件位于 `exp5/`，对应指导书《实验5》步骤2。文档性错误，但直接影响脚本溯源和评分。
- **修复建议**：改为"实验5 步骤2"。

## 🟡 小问题

1. **`step3_netem_loss.sh:16`、`step4_tcp_tuning.sh:13`、`step7_tcp_transfer.sh:21`**：`ip netns list | grep -q "$NS_RA"` / `"$NS_H56A"` 未锚定，属子串匹配。当前拓扑下无误报，但例如 `grep -q "RA"` 也会匹配未来任何含 "RA" 的命名空间名。建议用 exp1 已有的 `grep -qw`（实验1脚本已用 `grep -qw "$1"`，这里又退化了）。另外 step4/step7 只检查 H56A 存在，未检查 H57C。
2. **`step3_netem_loss.sh:11`**：`LOSS="${1:-10}"` 未校验，`./step3_netem_loss.sh abc`、负数、大于 100 的值都会直接把非法参数交给 tc，然后被 `set -e` 中止且报错不友好。建议加 `[[ "$LOSS" =~ ^[0-9]+([.][0-9]+)?$ ]] && ... && 检查 0<LOSS<=100`。
3. **`step1_check_env.sh`**：只用了 `set -u`，与本系列其他脚本的 `set -euo pipefail` 不一致（虽然该脚本每条命令都手动 `|| exit`，风险不大，但风格不统一）；第 18 行 `[ -n "${MISS:-}" ] && exit 1` 依赖 `&&` 短路而非显式 if，可读性差。另外该脚本检查了 GUI `wireshark`，但整套自动化只用 tshark（脚本内自述"等价 GUI"），检查项与实际依赖不完全对应——不算错，仅提示。
4. **`step7_tcp_transfer.sh:31`**：服务端日志硬编码 `/tmp/exp5_server.log`，与可参数化的 `PCAP_DIR` 风格不一致；多次运行会覆盖上一次日志，丢失排障线索。
5. **`step8_analyze_tcp.sh` 各 tshark 调用**：`2>/dev/null` 会吞掉 pcap 损坏、格式错误等诊断信息，出错时用户只看到空统计而无原因。
6. **`step4_tcp_tuning.sh` 末尾注释**：*"接收窗口最大 65536（窗口扩大后实际窗口 = 65536 << wscale）"* 表述有误——把 `tcp_rmem` max 限到 65536 后，内核会相应限制接收窗口（scaling 被上限约束），实际窗口不会"65536 << wscale"地放大；注释方向写反了，属文档瑕疵，不影响执行。
7. **步骤编号缺口（step2/5/6 缺失）**：README 已说明——步骤2 拓扑由 `create_topology.sh` 覆盖、offload 检查复用 `shell/exp3/step2_verify_offload.sh`（该文件确实存在且接口名/命名空间与 exp5 拓扑一致，仅记录 5 个 NS，与 exp3 要求一致），步骤5/6 折叠进 `step7_tcp_transfer.sh`。处理方式可接受，但 `step2_verify_offload.sh` 标题写的是"实验3 拓扑信息记录表"，复用输出会让实验5报告里出现"实验3"字样，复用时需自行改名。
8. **`step7_tcp_transfer.sh`**：`timeout 120` 硬编码；README 已注明丢包率高时偶发超长传输，建议也作为参数暴露。

## 与指导书的一致性核对（无问题项）

- **netem 位置与验证**：`step3` 在 RA 的 `ve-RA-RD` 挂 `netem loss 10%`、先 `del root` 再 `add`、用 `ping -c 20` 验证——与指导书步骤3逐条对应（接口命名风格 `ve-RA-RD` vs 指导书示例 `ve_RA_RD`，脚本已注释说明，属命名风格差异，全系列一致，不算缺陷）。qdisc 幂等性处理正确：`tc qdisc del ... root 2>/dev/null || echo` 先清后加，重复执行无问题。
- **TCP 调参**：`step4` 的 `tcp_rmem='4096 65536 65536'` 与 `tcp_sack=0` 与指导书步骤4(3)(4)完全一致，且按命名空间分别设置（netns 隔离生效范围正确），并回读校验。
- **传输与分析**：`step7` 的 100K 文件（`truncate -s 100K` = 102400 字节，与校验值一致）、`ncat -lv 4499 > 100K_57C.dat`、`ncat 192.168.57.254 4499 < 100K_56A.dat` 与指导书步骤5/7一致；抓包选在发送端 H56A 的 `ve-H56A`，与指导书步骤6（H56A 上 Wireshark）方向一致，且比指导书更适合观察重传。`step8` 的 `tcp.analysis.fast_retransmission` / `duplicate_ack` 字段使用正确。
- **IP 规划**：`create_topology.sh` 的 H56A 192.168.56.126/25、H57C 192.168.57.254/26、互联 /30 地址（.244–.247、.252–.255 的可用端）与指导书及拓扑图一致，静态路由经核对互通正确。
- **`step1_check_env.sh`、`step4_tcp_tuning.sh`**（除上述小问题外）：未发现功能性 bug。
- **`README.md`**（除第 8 条方向说明外）：执行顺序、预期现象描述与脚本行为基本一致。

## 结论

实验5脚本整体忠实还原了指导书流程（netem 位置、调参取值、传输命令均正确），但 `step8_analyze_tcp.sh` 有三个会直接产出错误分析结果的真实 bug（SIGPIPE 中断、部分 ACK 误标、伪重传双计），且 `create_topology.sh` 把实验1已修复的幂等/回滚和 `bridge link show` 参数 bug 又原样带了回来——优先修 step8 与拓扑脚本即可。
