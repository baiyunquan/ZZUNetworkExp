# 实验3 脚本严苛审查报告

> 审查者：subagent（OpenCode Go / Glm 5.3 Flash）· 2026-09-06
> 审查范围：`shell/exp3/` 全部脚本 + `README.md`，对照 `instruction/03_实验3.md`。所有"已验证"结论均在宿主机上以只读命令实测（`bridge link show`、`ip -o` 输出格式、`pipefail+head` 退出码等），未改动任何文件、未创建命名空间。

---

## 🔴 确认的 Bug

### 1. `bridge link show` 位置参数被静默忽略（与实验1同类问题）
- **文件**：`create_topology.sh` 第 139–140 行
- **问题原文**：
  ```bash
  ip netns exec "$NS_SW56A" bridge link show "$BR_56A"
  ip netns exec "$NS_SW57C" bridge link show "$BR_57C"
  ```
- **为什么错**：`bridge link show` 的语法是 `bridge link show dev DEV`，不存在位置参数。实测：`bridge link show nonexistentjunk` 退出码 0，照常列出所有网桥端口——传入的 `br_SW56A` 被静默丢弃。此处碰巧每个交换机命名空间只有一个网桥所以"看起来对"，但语义完全错误：它列出的不是指定网桥的端口，而是该命名空间内**所有**网桥的端口；若未来拓扑加第二个网桥，验证结果会失真且永远不报错。
- **修复建议**：改为 `ip netns exec "$NS_SW56A" ip link show master "$BR_56A"`（按 master 过滤，语义正确），或 `bridge link show`（列出本 ns 全部端口并去掉误导性参数）。

### 2. `grep -v " lo "` 无法过滤回环接口（与实验1同类问题，已实测）
- **文件**：`step2_verify_offload.sh` 第 17 行
- **问题原文**：
  ```bash
  ip netns exec "$ns" ip -o link show 2>/dev/null | grep -v " lo " | while IFS= read -r line; do
  ```
- **为什么错**：实测本机 `ip -o link show` 输出为 `1: lo: <LOOPBACK,UP,LOWER_UP> ...`——是 `" lo:"`（后跟冒号）而非 `" lo "`，`grep -v " lo "` 匹配不到。实测过滤后行数不变，`lo` 照样进入记录表，还会输出 `IP: 127.0.0.1/8`，污染拓扑记录材料。
- **修复建议**：用 `awk -F': ' '$2!="lo"'` 或 `ip -o link show | grep -vE '^[0-9]+: lo:'`。

### 3. `cut -d: -f2` 解析出 `name@peer`，导致所有 VETH 的 IP 记录为空（已实测，最严重）
- **文件**：`step2_verify_offload.sh` 第 18、21 行
- **问题原文**：
  ```bash
  ifname=$(echo "$line" | cut -d: -f2 | tr -d ' ')
  ...
  ip netns exec "$ns" ip -o addr show dev "$ifname" 2>/dev/null \
      | grep -oE 'inet [0-9a-fA-F:./]+' | sed 's/^/    IP: /'
  ```
- **为什么错**：`ip -o link show` 下 VETH 显示为 `2: ve-H56A@ve-SW56A-H56A: <...>`，`cut -d: -f2` 取出的是 `ve-H56A@ve-SW56A-H56A`（含对端后缀）。实测 `ip -o addr show dev "lo@lo"` → `Device "lo@lo" does not exist.`（退出码 1）。于是**每个 VETH 的 `ip addr show dev` 都失败**，且错误被 `2>/dev/null` 吞掉——记录表的 IP 列对全部 VETH 为空。步骤2(3) 要求"记录 VETH 接口的 IP 地址"，这个核心输出完全失效；同时"接口"列也错误地带上了 `@peer` 后缀。只有回环口（因 bug 2 未被过滤）反而能正常显示 IP，极具讽刺性。
- **修复建议**：`ifname=${line%%@*}` 或 `cut -d: -f2 | cut -d@ -f1 | tr -d ' '`，并去掉 `2>/dev/null` 或在取不到 IP 时报警。

### 4. `set -euo pipefail` + `tshark | head -10`：报文多于 10 条时脚本中途自杀（已实测同类行为）
- **文件**：`step4_analyze_udp.sh` 第 12、19 行
- **问题原文**：
  ```bash
  tshark -r "$PCAP" -Y "udp" 2>/dev/null | head -10
  ...
  2>/dev/null | head -10
  ```
- **为什么错**：脚本第 5 行 `set -euo pipefail`。当 pcap 中 UDP 报文超过 10 条时，`head` 提前退出，`tshark` 收到 SIGPIPE 非正常结束，管道退出码非零。实测 `bash -c 'set -o pipefail -e; seq 1 100000 | head -3; echo next'` 外层退出码 **141**——脚本在第 (1) 步就直接中断，第 (2)(3)(4) 步根本不会执行。报文少时侥幸通过，属于潜伏型时序炸弹。
- **修复建议**：改为 `tshark ... | head -10 || true`，或用 tshark 自身截断：`tshark -r "$PCAP" -Y udp -c 10`，或把 `set -e` 改为对该管道显式容错。

### 5. `create` 不幂等：重复执行在 `set -e` 下中途爆掉（与实验1同类问题）
- **文件**：`create_topology.sh` `do_create()`（第 48–50 行起）
- **问题原文**：
  ```bash
  for ns in ...; do
      ip netns add "$ns"
  done
  ```
- **为什么错**：无任何前置检查/清理。拓扑已存在时重跑 `create`，第一条 `ip netns add` 即报 `File exists`，`set -e` 使脚本立即中止——此时可能已删/建了一半，留下"半成品拓扑"，且没有 `trap` 做回滚。README 快速开始的流程一旦某步失败重试，就会踩中。
- **修复建议**：`create` 前先执行静默 `destroy`（或逐项 `ip netns del ... 2>/dev/null || true`），`ip addr add` 一律加 `|| { echo 报错; }` 提示而不是让 set -e 裸崩。

### 6. `offload_off` 静默吞错 + verify 不检查 offload，核心要求可能静默失效
- **文件**：`create_topology.sh` 第 43–46 行、`do_verify()`
- **问题原文**：
  ```bash
  offload_off() {
      local ns="$1" ifname="$2"
      ip netns exec "$ns" ethtool -K "$ifname" rx off tx off gso off tso off gro off 2>/dev/null || true
  }
  ```
- **为什么错**：指导书明确"本实验需关闭网卡 offload，保证 IP 分片、UDP 校验和等计算均由 CPU 完成"——这是本实验能验证校验和的前提。但此处 `2>/dev/null || true` 把 ethtool 缺失、接口名错、内核不支持等一切失败全部吞掉，offload 可能全部仍是 on 而脚本显示"==> 关闭所有主机/路由器 VETH 的 offload（实验要求）"和"==> 拓扑创建完成"。同时 `do_verify()` 完全不复查 offload 状态，步骤2(4) 的验证闭环缺失。参数取值本身（rx/tx/gso/tso/gro off）与指导书一致，无问题。
- **修复建议**：失败时 `echo "[警告] $ns.$ifname offload 关闭失败"` 至少留痕；`verify` 中加 `ethtool -k` 抽查并断言为 off。

### 7. traceroute 预期跳数错误：写了 3 跳，实际拓扑是 4 跳
- **文件**：`create_topology.sh` 第 188 行注释、`README.md` 第 24、45 行
- **问题原文**：
  ```
  6) traceroute 输出 3 跳: 192.168.56.1(RB) -> 192.168.56.246(RA)
     -> 192.168.57.254(H57C)，与拓扑路径 RB-RA-RD 一致。
  ```
  README："`traceroute` 输出 3 跳：`192.168.56.1(RB) → 192.168.56.246(RA) → 192.168.57.254(H57C)`"
- **为什么错**：路径是 H56A→RB→RA→RD→H57C，共 3 台路由器。TTL=3 的包在 **RD** 处 TTL 减到 0，RD 会回 ICMP Time Exceeded——第 3 跳是 RD（192.168.56.254 或 57.193），第 4 跳才是 H57C。注释甚至自相矛盾："3 跳 ... 与拓扑路径 RB-RA-RD 一致"却没列 RD。学生按此核对实验现象会误判为异常。
- **修复建议**：改为 4 跳：`192.168.56.1(RB) → 192.168.56.246(RA) → RD(192.168.56.254) → 192.168.57.254(H57C)`。

### 8. tshark 全部输出被丢弃 + 固定 sleep 时序（与实验1同类问题）
- **文件**：`step3_udp_comm.sh` 第 25、27 行
- **问题原文**：
  ```bash
  ip netns exec "$NS_H57C" tshark -i "$IF_H57C" -w "$PCAP" >/dev/null 2>&1 &
  TS_PID=$!
  sleep 2
  ```
- **为什么错**：① tshark 的 stdout/stderr 全进 /dev/null——若抓包根本没起来（如用户传入的 `PCAP_DIR` 目录不存在、`-w` 打不开文件、权限问题），脚本毫无感知，一路跑到最后 `ls -l "$PCAP"` 才以一条莫名其妙的错误崩掉（`set -e`），用户无从知道真实原因。② 抓包是否就绪靠 `sleep 2` 猜测，tshark 在 netns 内冷启动慢时，最早几包（甚至整个 UDP 会话）可能没进 pcap，与实验1已发现的"依赖 sleep 时序导致 pcap 截断"同型。
- **修复建议**：捕获 tshark stderr 到日志文件并在启动后 `kill -0 $TS_PID` 探活；用 `sleep 2` 后检查 `ls -s "$PCAP"` 非空，或给 tshark 加 `-a duration:` 代替 kill。

---

## 🟠 明显缺陷

### 9. step3 不清理旧进程/不检查端口占用，重复执行结果不可信
- **文件**：`step3_udp_comm.sh` 第 31–33 行
- 上一次运行被 Ctrl-C 中断时，netns 里的 `ncat -lvu 4499` 和 tshark 会残留（脚本没有 `trap ... EXIT` 清理）。重跑时新服务端 `bind` 失败，错误被写进 `/tmp/exp3_server.log` 无人查看，客户端实际在和**旧服务端**通信，脚本照常"验证 ✓"。建议开头 `pkill` 残留进程 + 增加 `trap cleanup EXIT`。

### 10. step2 的 offload "检查"只打印、不断言，命名空间缺失时静默输出空表
- **文件**：`step2_verify_offload.sh` `check_offload()`（第 46–52 行）
- 函数只 `grep` 后 `sed` 打印，从不判断值是否为 `off`；`ip netns exec ... 2>/dev/null` 吞掉一切错误——拓扑没建时，输出是 8 个只有标题没有内容的空段，退出码 0。脚本自称"offload 状态检查"却没有任何检查结论，与"摆设式环境检查"同型。应对 `: on` 的行报警并 `exit 1`。

### 11. step2 拓扑记录表漏掉两个交换机命名空间
- **文件**：`step2_verify_offload.sh` 第 11 行
- 循环只遍历 `H56A H57C RB RA RD`。指导书步骤2(3) 明确要求记录"主机、**交换机**和路由器的命名空间（NS）名称、NS 内 VETH 接口名称……"，SW56A/SW57C 内各 2 个 VETH 未被记录，记录材料不完整。

### 12. step1 的模块检查是摆设：失败时不报错、不置 MISS、退出码 0
- **文件**：`step1_check_env.sh` 第 34–35 行
  ```bash
  modinfo veth   >/dev/null 2>&1 && echo "    veth ✓"
  modinfo bridge >/dev/null 2>&1 && echo "    bridge ✓"
  ```
  模块文件不存在时既无错误提示也不计入 `MISS`，脚本照样成功退出；且 `modinfo` 只证明模块文件存在，不证明可加载。要么失败即 `MISS=1`，要么删掉这两行。

### 13. step3 的"双向通信验证"名不副实，且失败不改变退出码
- **文件**：`step3_udp_comm.sh` 第 35–44 行
- 指导书步骤5 要求客户端、服务端**两个方向**各手动发送一行字符；脚本只从 H56A 发了一条，"服务端回发"实为 `ncat -e /bin/cat` 回显。回显不匹配时仅打印"[提示]……"后以退出码 0 结束——自动化脚本无法用于判定实验成败。另外第 56 行自称"服务端收到的内容"一节，实际 `/tmp/exp3_server.log` 被自己承认是空的（`-e` 模式数据走网络不走 stdout），纯误导；且该日志路径硬编码 `/tmp`，与可配置的 `PCAP_DIR` 不一致。

### 14. step4 分析未限定实验会话，且 UDP 校验和解读有偏差
- **文件**：`step4_analyze_udp.sh` 第 12、38 行
- `-Y "udp"` 不过滤 `udp.port==4499`，一旦 ns 内有其他 UDP 流量，字段表会混入无关报文，`uniq -c` 统计也随之失真。注释里"校验和……可选但 IPv4 下常算"表述含糊——RFC 768 中 IPv4 的 UDP 校验和可选（全 0 表示不计算），但 Linux 协议栈总是计算，此处应说明为"Linux 下必算"。

---

## 🟡 小问题

1. **`step3_udp_comm.sh` 第 35 行**：UDP 无半关闭/EOF 语义，`ncat -u` 在 stdin EOF 后可能挂到 `timeout 6` 超时——每次运行固定耗时约 6 秒（建议改用 `timeout 2` 或发送后主动 kill）。另 `2>/dev/null` 使 `ncat: command not found` 之类错误也静默。
2. **`create_topology.sh` `do_create()`**：网桥在第 57–60 行 `ip link set up` 一次，第 118–119 行又 up 一次，冗余（无害但说明代码未经梳理）。
3. **`create_topology.sh` `do_verify()`**：`ping -c 4` 失败时在 `set -e` 下直接中止，traceroute 永远执行不到，且无任何友好提示（对比：`step3` 至少有提示语）。
4. **`step3_udp_comm.sh` 第 21 行**：`ip netns list | grep -q "$NS_H57C"` 模式未锚定，名为 `H57C-bak` 的残留 ns 也会通过检查。
5. **`step4_analyze_udp.sh` 第 24–29 行**：UDP 首部 ASCII 图列错位（"长度"占 16–31 位、与"校验和"框重叠画法错误），作为给学生的教学材料不应画错。
6. **`README.md` 第 8 行**：称 `step3_udp_comm.sh` 作用为"模拟主机终端 + ……"，脚本实际不模拟终端（仅在末尾注释描述交互方法），文档与行为不符。
7. **`step1_check_env.sh` 第 19 行**：缺工具提示里只给了 nmap/traceroute/ethtool 的安装命令，唯独漏了 wireshark/tshark 的安装提示。
8. **`step1_check_env.sh` 第 13 行**：`[ ... ] && echo ✓ || { ...; exit 1; }` 的 `&&...||` 链式写法，若 echo 失败也会进入错误分支——此处无实害，但属易错惯用法。

---

## 结论

实验3 的**拓扑脚本（create_topology.sh）整体正确**：IP 规划、/30 取址、静态路由、ip_forward、offload 参数均与指导书一致，但存在不幂等、offload 静默失败、`bridge link show` 假验证和错误的 traceroute 跳数预期；**step2_verify_offload.sh 的记录表基本报废**（`grep -v " lo "` 失效 + `cut` 解析出 `@peer` 导致全部 VETH 的 IP 记录为空），是本批最需优先修复的文件；step3/step4 则继承了实验1已见的 sleep 时序、`pipefail+head` 自杀、错误静默与进程残留等通病。
