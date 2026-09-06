# 实验4 脚本审查报告

> 审查者：subagent（OpenCode Go / Glm 5.3 Flash）· 2026-09-06
> 审查范围：`shell/exp4/` 全部 5 个 `.sh` 文件 + `README.md`，对照 `instruction/04_实验4.md`。以下行号均为当前文件实际行号。

## 🔴 确认的 Bug

### 1. `create_topology.sh:41` — create 不幂等，重跑即中途失败
```bash
for ns in ...; do ip netns add "$ns"; done
```
`set -euo pipefail` 下，重复执行 `create` 时第一条 `ip netns add` 报 `Error: argument "H56A" already exists` 直接以非零退出，脚本在"建了一半"的状态中止（此时部分 netns 可能已新建、部分旧拓扑残留），后续 IP/路由不会配置。这是实验1已发现的同类问题。修复：先检查存在则 `destroy` 或逐条 `ip netns add "$ns" 2>/dev/null || true` + 显式校验结果。

### 2. `create_topology.sh:116-117` — `bridge link show` 缺 `dev`，参数被静默忽略（验证形同虚设）
```bash
ip netns exec "$NS_SW56A" bridge link show "$BR_56A"
```
实测（本机复现）：`bridge link show foobarbaz` 退出码 0 且照常输出所有网桥端口——位置参数 `br_SW56A` 被静默丢弃。此命令实际等价于 `bridge link`，**无论网桥名写错与否都会"通过"**，是摆设式检查。且按语义应写 `bridge link show dev br_SW56A`（或直接 `bridge link` 列出端口）。注意：指导书原文就是这么写的，脚本照抄了指导书的错误命令，但作为"要求实现的验证脚本"应当修正。

### 3. `step6_tcp_file_transfer.sh:35-47` — 客户端挂死→`timeout` SIGTERM 强杀，**抓不到四次挥手**，与脚本自述的"预期现象"直接矛盾
```bash
echo "cat /root/3500.dat" | timeout 15 ip netns exec "$NS_H56A" ncat "$SERVER_IP" "$PORT" > "$RECV_FILE" 2>/dev/null || true
...
kill "$SRV_PID" ...
```
问题链条：
- 服务端是 `ncat -e /bin/sh`，`/bin/sh` 执行完 `cat` 后继续等下一条命令，**永远不会主动退出**，服务端不会发 FIN；
- nmap ncat 在 stdin EOF 后默认保持连接等对端关闭（与传统 `nc` 的 EOF 半关闭不同），客户端会一直挂到 `timeout 15` 被 **SIGTERM** 杀死——进程被信号杀死，内核发的是 **RST** 而非优雅 FIN；
- 即使某版本 ncat 行为不同，`kill "$SRV_PID"` 也是对存活连接 SIGTERM，同样倾向产生 RST。

结果：pcap 中大概率只有 RST 报文，`tcp.flags.fin==1` 过滤为空，脚本第 47 行注释"客户端 EOF 触发 FIN……四次挥手"与 README"四次挥手：FIN,ACK → ACK → FIN,ACK → ACK"的预期现象**在自动化路径上无法成立**。修复：向远程 shell 追加 `exit` 使 `/bin/sh` 正常退出，例如 `printf 'cat /root/3500.dat\nexit\n' | timeout 15 ...`，让服务端先优雅关闭。

### 4. `step6_tcp_file_transfer.sh:26-31` — 后台进程启动失败被完全吞掉，脚本"成功"跑完但产物为空
```bash
ip netns exec "$NS_H57C" tshark -i "$IF_H57C" -w "$PCAP" >/dev/null 2>&1 &
TS_PID=$!
sleep 2
...
ip netns exec "$NS_H57C" ncat -e /bin/sh -lv "$PORT" > /tmp/exp4_server.log 2>&1 &
SRV_PID=$!
sleep 1
```
- tshark 的 stderr 被丢进 `/dev/null`：接口名不对、权限不足、pcap 目录不存在（`PCAP_DIR` 是用户参数，脚本从不 `mkdir -p`，第 49 行 `ls -l "$PCAP"` 才会以晦涩错误炸出 `set -e`）；tshark 启动即死时脚本照常继续，最后得到空/缺失 pcap。
- 服务端同理：若 4499 端口被上次残留的 ncat 占用（见缺陷 6），`Address already in use` 只落在日志里，脚本不检查，客户端连不上，`RECV_SIZE=0` 只打印"[提示]"就当作正常流程结束，退出码 0。
- 固定 `sleep 2`/`sleep 1` 时序替代就绪检测，是实验1已发现的"依赖 sleep 时序"同类缺陷。修复：启动后用 `kill -0` 探活 + 检查 `ss -tln 'sport = :4499'` 就绪；错误输出留档而非丢弃。

### 5. `step7_analyze_tcp.sh:15/27/33` — `set -euo pipefail` 下 `tshark | head` 的 SIGPIPE 会让脚本中途静默死亡
```bash
    2>/dev/null | head -5
```
实测验证：`bash -c 'set -euo pipefail; yes | head -3; echo REACHED'` → `REACHED` 未打印，退出码 141。当 pcap 中 SYN 报文超过 5 条（重传、多次连接）或 FIN 超过 6 条时，`head` 提前关管道 → tshark 收到 SIGPIPE → `pipefail` 使管道返回 141 → `set -e` 中止脚本，**(1) 之后的所有分析段全部丢失**。修复：`head -5 || true`，或用 `tshark -c 5`/awk 限行替代 `head`。

### 6. `create_topology.sh:130-135` — destroy 不杀进程，残留进程可污染下一轮实验
```bash
for ns in ...; do ip netns del "$ns" 2>/dev/null || true; done
```
destroy 只删 netns 与 veth，不杀运行中的 `ncat`/`tshark`（它们通过 `ip netns exec` 启动，属于宿主 PID）。删除 netns 后这些进程留在"无名字"的死 netns 里继续存活；若 ncat 仍在监听 4499，下一次 `step6` 的服务端会因端口占用失败（而脚本又检测不到，见 Bug 4）。与实验1的"destroy 不杀进程"同类。修复：destroy 前 `pkill`/按 netns 内 `/proc` 扫描清理相关进程。

## 🟠 明显缺陷

### 7. `create_topology.sh`（do_create 全程）— 所有命名空间的 loopback 未启用
脚本只把 veth/网桥 up，从不执行 `ip link set lo up`。netns 内 `lo` 默认 DOWN：`ncat -e /bin/sh` 监听 `0.0.0.0`（含 127.0.0.1 地址段）、shell 内任何回环访问都会出问题；对"TCP 连接管理"实验而言，lo down 也是常见的异常源。exp1/exp3 的 create 脚本同样缺失（grep 确认无 `lo up`），属整套脚本的系统性遗漏。

### 8. `step6_tcp_file_transfer.sh:46-47` — `ncat -e /bin/sh` 的子 shell 可能成为孤儿进程
`kill "$SRV_PID"` 只杀 ncat 本体；`-e` 拉起的 `/bin/sh` 子进程是否随父进程被回收取决于 ncat 的信号处理。若成孤儿，它会一直持有 4499 连接直至下轮 `destroy`（而 destroy 又不杀进程，见 Bug 6）。脚本缺少 `pkill -P "$SRV_PID"` 或进程组清理（`setsid`/`kill -- -$PID`）。

### 9. `create_topology.sh:125` — `set -e` 下 verify 的 ping/traceroute 失败会无消息中止
```bash
ip netns exec "$NS_H56A" ping -c 4 192.168.57.254
ip netns exec "$NS_H56A" traceroute 192.168.57.254
```
ping 全丢或 traceroute 失败时脚本以非零码静默退出（且 traceroute 不再执行），用户得不到任何诊断信息。应加 `|| { echo "验证失败..." >&2; exit 1; }`。

### 10. `step4_create_testfile.sh:17` — 文件落在宿主 `/root`，"在 H57C 上创建"是假象
`ip netns exec H57C truncate -s 3500 /root/3500.dat`：netns 共享文件系统，文件实际创建在**宿主机** `/root/3500.dat`，H56A/H57C 都看得见。功能上无碍（step6 客户端也用绝对路径），但与指导书"在 H57C 的模拟终端执行 `truncate -s 3500 3500.dat`"的语义有偏差，且 `destroy` 后文件残留 `/root`（连同 `/tmp/exp4_received.dat`、`/tmp/exp4_server.log`），无任何清理。

### 11. `step6_tcp_file_transfer.sh:35` — `|| true` 掩盖传输失败，错误判定全靠"文件大小恰好等于 3500"
`... || true` 使客户端连接拒绝、timeout 被杀等任何异常都不影响流程；第 39 行以 `RECV_SIZE -eq 3500` 判断成功。若传输中途被 SIGTERM 截断收到 3499 字节，同样只打"[提示]"。且 `2>/dev/null` 丢弃了 ncat 的连接错误信息，排查只能翻 `/tmp/exp4_server.log`（服务端日志，还看不到客户端侧错误）。

### 12. `step7_analyze_tcp.sh:14-33` — `2>/dev/null` 吞掉 tshark 全部错误
字段名/过滤器写错、pcap 损坏时，tshark 静默失败输出空结果，脚本每个分析段打印空行后"成功"退出。配合 Bug 5（SIGPIPE），该分析脚本对失败完全不设防。应至少校验 `tshark -r "$PCAP" -Y tcp -c 1` 可读，或检查各管道退出码。

### 13. `README.md` — 复用的 `shell/exp3/step2_verify_offload.sh` 自带已知 bug
README 明确指导"步骤2(3)(4) 可直接复用 `shell/exp3/step2_verify_offload.sh`"，但该脚本（第 17 行）`ip -o link show | grep -v " lo "` 是实验1已证实的无效过滤：`ip -o` 输出格式为 `1: lo: ...`，子串 ` lo `（空格-lo-空格）不匹配 `: lo:`，lo 不会被过滤，会混进"拓扑信息记录表"；且脚本标题硬编码"实验3 拓扑信息记录表"，用于实验4报告时名称错位。README 未提示这两点。

## 🟡 小问题

1. **`step1_check_env.sh:33-35`**：`modinfo veth ... && echo` 是摆设式检查——modinfo 只说明模块元数据存在，不验证可加载；若内核将 veth/bridge 编译内建（无 modinfo），最后一条 `modinfo bridge && echo` 失败还会让脚本以退出码 1 结束（无 `set -e`，但脚本的返回值取自最后命令），产生"全绿却失败"。
2. **`step1_check_env.sh:19`**：`MISS=1` 未加 `local`/声明即用，靠 `set -u` + `${MISS:-}` 兜底，风格脆弱但功能正确。
3. **`step4_create_testfile.sh` 尾注**："大于以太网 MSS（1460）但小于 MTU 可承载的两段"说法错误：2×1460=2920 < 3500，3500 字节需要 **3 段**（1460+1460+580），注释与同句"约 3 段"自相矛盾。
4. **`step4/step6` 的 `ip netns list | grep -q "$NS_H57C"`**：子串匹配，若存在 `H57C-backup` 之类的命名空间会误判"拓扑已创建"。
5. **`step7_analyze_tcp.sh` 尾注"恰好 2 个 SYN 报文"**：发生 SYN 重传时会更多，而 Bug 5 恰在 >5 条时致命；分析段 (1)(3) 也未按端口 4499 过滤，多连接 pcap 会混入无关报文。
6. **`step7_analyze_tcp.sh` 首部 ASCII 图**：标志位一行漏了 CWR/ECE/NS，且保留位与标志位的比特宽度未按 4+6+9(或 4+6+6) 对齐，仅教学示意层面粗糙，不影响脚本运行。
7. **`create_topology.sh` destroy 的 `ip link del` 循环**（134 行）：删除 netns 时其内 veth 对端已被销毁，宿主侧手动删除基本是冗余代码（无害）。

## 各文件结论

| 文件 | 结论 |
|---|---|
| `create_topology.sh` | 🔴 Bug 1/2/6，🟠 缺陷 7/9 |
| `step1_check_env.sh` | 🟡 1/2（无致命问题） |
| `step4_create_testfile.sh` | 🟠 缺陷 10，🟡 3/4 |
| `step6_tcp_file_transfer.sh` | 🔴 Bug 3/4（本组最严重），🟠 缺陷 8/11 |
| `step7_analyze_tcp.sh` | 🔴 Bug 5，🟠 缺陷 12，🟡 5/6 |
| `README.md` | 🟠 缺陷 13（复用带 bug 的 exp3 脚本）；步骤编号跳缺（无 step2/step3/step5 文件）已通过表格、复用说明和交互式章节解释清楚，与指导书对应关系无遗漏，这点**没有问题** |

## 结论

实验4脚本的拓扑与 IP 规划本身正确，但自动化链路在最核心的两个环节上不可信：`step6` 抓不到指导书要求观察的"四次挥手"（客户端被 `timeout` SIGTERM 强杀产生 RST），且后台进程启动失败被静默吞掉；`step7` 的 `pipefail + head` 组合会在报文稍多时中断分析。加上沿用实验1的幂等性、`bridge link show`、进程清理三类老问题，建议按上述 🔴 项优先修复后再跑实验。
