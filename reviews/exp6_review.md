# 实验6 脚本审查报告

> 审查者：subagent（OpenCode Go / Glm 5.3 Flash）· 2026-09-06
> 审查范围：`shell/exp6/` 全部脚本 + `README.md`，对照 `instruction/06_实验6.md`（只读审查，未修改任何文件）

## 🔴 确认的 Bug

### 1. `create_topology.sh`：静态路由把**本机地址**当下一跳，`set -e` 下拓扑创建必然中途失败
- **文件/行号**：`create_topology.sh:173-174`、`178-179`、`186-188`
- **问题原文**：
  - L173-174（RC）：`ip route add 192.168.56.0/25 via 192.168.56.249` / `ip route add 192.168.99.0/24 via 192.168.56.249`
  - L178-179（RD）：`via 192.168.56.253`
  - L186-188（RA）：`via 192.168.56.250`、`via 192.168.56.254`（两条）
- **为什么错**：按脚本自己的地址规划（L41-43）：RC 侧 RA 链路本机地址就是 `192.168.56.249`（`IP_RC_RA`），RD 本机是 `.253`（`IP_RD_RA`），RA 本机是 `.250`/`.254`（`IP_RA_RC`/`IP_RA_RD`）。`via` 后面必须是**对端路由器**的地址，写本机地址会被内核拒绝（`Error: Nexthop has invalid gateway.` / RTNETLINK EINVAL）。对比 L168-171（RB）写的是对端 `.246`（RA 的地址），是唯一正确的一组，恰好暴露了其余三组的系统性写反。
- **后果**：脚本在 L173 处第一次 `ip route add` 失败，`set -e` 直接终止 —— `create` 永远跑不到 RA 路由、offload 配置和完成提示，留下半成品拓扑。
- **修复建议**：
  - RC（L173-174）：`via 192.168.56.250`（RA 侧地址）
  - RD（L178-179）：`via 192.168.56.254`
  - RA（L186）：`57.0/25 via 192.168.56.249`（RC）；L187：`57.128/26 via 192.168.56.249`（走 RC 才与 step8 宣称的 `RB→RA→RC→RE` 路径一致，见缺陷 #12）；L188：`57.192/26 via 192.168.56.253`（RD）

### 2. `step3_set_mtu.sh`：引用未定义变量 `$NS_H56A`，`set -u` 下回归测试必崩
- **文件/行号**：`step3_set_mtu.sh:26`
- **问题原文**：`ip netns exec "$NS_H56A" ping -c 2 192.168.57.254 2>/dev/null || \`（下一行 fallback 又用字面量 `H56A`）
- **为什么错**：本文件只定义了 `NS_RA`/`NS_RB`（L8），`NS_H56A` 从未定义；脚本头部是 `set -euo pipefail`，展开未绑定变量即报 `NS_H56A: unbound variable` 并以非零退出。MTU 其实已改成功，但脚本最后一步必失败、退出码非零。
- **修复建议**：文件头加 `NS_H56A="H56A"`；删除多余的 `2>/dev/null || ip netns exec H56A ...` 兜底（它还会把第一次 ping 的真实报错吞掉）。

### 3. 分片数学错误：片1 总长是 **996** 不是 1000（三处文档互相矛盾且与内核行为不符）
- **文件/行号**：`step6_ip_fragment.sh:53-55`、`step7_analyze_fragment.sh:51` 与 `65`、`README.md:55`
- **问题原文**：
  - step6 L54：`片1: 总长 1000（IP头20 + 数据980，实际按8字节对齐取976+4填充对齐，`
  - step7 L51：`ip.len          1428                  片1=1000, 片2=452`
  - README L55：`片1 len=1000/MF=1/offset=0，片2 len=452/...`
- **为什么错**：除最后一片外分片数据必须 8 字节对齐。MTU 1000 − IP头 20 = 980，向下取整到 976，故**片1 ip.len = 20+976 = 996**，片2 = 20 + (1428−996) = 452。IP 分片**不存在"填充对齐"**（step6 L54 的说法是原理性错误）；且 step7 L57 自己写的数据划分 `片1=976B + 片2=432B`（20+976=996）与同表 L51 的 `片1=1000` 直接矛盾。照此文档核对实验结果必然"对不上"。
- **修复建议**：统一改为片1 `ip.len=996`，并删除"976+4填充对齐"的错误解释；`README.md:60` 的"976B 数据（976/8=122）"部分正确，但与 L55 的 `len=1000` 冲突，需一并订正。

### 4. `step7_analyze_fragment.sh`：`ip.frag_offset` 单位写错，预期输出与 tshark 实际输出不符
- **文件/行号**：`step7_analyze_fragment.sh:53`、`66`
- **问题原文**：`ip.frag_offset  0                     片1=0, 片2=122(=976/8)`；注释 `片2: ip.len=452, mf=0, frag_offset=122`
- **为什么错**：tshark 的 `-e ip.frag_offset` 输出的是**字节偏移**（本机 `tshark -G fields` 验证该字段为 `BASE_DEC` 的字节数字段），片2 实际会打印 **976**，不是 122（122 是 8 字节单位的片偏移，需自行除 8 或用 `-e ip.checksum` 之外的换算字段）。
- **修复建议**：文档改为 `片2=976（字节）= 122×8`，或在提取时用 `-e ip.frag_offset` 后注释说明单位；不要让"预期输出"与工具实际输出对不上。

### 5. `create_topology.sh:210`：`bridge link show` 缺 `dev` 关键字，验证形同虚设（实验1同类 bug 复现）
- **文件/行号**：`create_topology.sh:210`
- **问题原文**：`ip netns exec "${spec%% *}" bridge link show "${spec#* }"`
- **为什么错**：已实测验证：`bridge link show nonexistent_dev` 仍输出无关网桥端口（如 `veth5b9aa93@enp6s0 ... master br-ea79...`），多余位置参数被静默忽略，`bridge link show` 根本不支持按设备名过滤。于是 `verify` 打印的是该命名空间下**全部**端口，且即使设备没绑上桥也显示"正常"。
- **修复建议**：`bridge link show dev "$BR"`，或 `ip link show master "$BR"`。

### 6. `step6_ip_fragment.sh` / `step7_analyze_fragment.sh`：抓包与解析链路存在"静默失败→分析陈旧数据"风险
- **文件/行号**：`step6_ip_fragment.sh:31-33`（tshark `>/dev/null 2>&1 &`）、`step7_analyze_fragment.sh:15-22`
- **为什么错**：
  1. step6 中两个 tshark 的全部输出（含致命错误）被丢弃：若 `$PCAP_DIR` 不存在、接口名不对、权限不足，tshark 立即退出也无人知晓；旧的 `/tmp/exp6_rb_*.pcap`（上次运行残留）不会被清理，`step7` 会拿着**上次的旧包**"成功"分析，且不报任何异常。
  2. step7 只检查 `PCAP_IN` 存在性（L15），**不检查 `PCAP_OUT`**；L22 的 tshark `2>/dev/null` 把"文件不存在"的报错也吞掉，`set -e` 会在 (2) 处无提示地终止，(3)(4) 的解读内容永远打印不出来。
- **修复建议**：step6 启动后 `sleep` 后探测两个 tshark 进程存活 + 删除/校验 pcap 新建时间；step7 对两个 pcap 都做存在性和非空（`capinfos`/`tshark -r ... -c 1`）检查，去掉 `2>/dev/null`。

## 🟠 明显缺陷

7. **`create_topology.sh` create 不幂等**（实验1同类问题）：重复执行 `create` 在 L68 `ip netns add` 处报 "File exists" 并因 `set -e` 中断，留下已建的网桥/VETH 残骸；没有 `create` 前自动 `destroy` 或存在性预检。
8. **`create_topology.sh` destroy 不清理命名空间内进程**（L225-236）：step6 留下的 `ncat -lvu 4499`、若用户手动启动的 `tshark` 不会被杀；`ip netns del` 只摘名字，进程迁入无名命名空间继续持有接口，"已清理"提示不属实。
9. **`create_topology.sh:39` offload 关闭是"摆设"**：`ethtool -K ... rx off ... 2>/dev/null || true` 吞掉一切错误。veth 通常**不允许关闭 rx-checksumming**（返回 "Could not change any device features"），被静默忽略后指导书步骤2(4) 的 rx off 要求既没落实也没有任何后续校验（verify 中也不检查 offload 状态）。
10. **`step6_ip_fragment.sh` 依赖 sleep 时序**（实验1同类问题）：L34 `sleep 2` 后才发 nping，系统繁忙时 tshark 可能尚未在两接口就绪，导致 pcap 截断/漏包；且脚本没有任何"pcap 内确实抓到 1428B 原始包 + 2 个分片"的断言，成败全靠人眼看 step7。
11. **`step8_traceroute_routes.sh:34` `routel | head -8 || ip route | head -8`**：在 `pipefail` 下，路由表超过 8 行时 `head` 关闭管道使 `routel` 死于 SIGPIPE（退出码 141），`||` 被误触发，重复打印一遍 `ip route`；`head -8` 还会任意截断路由表。应改 `routel ... | head -8` 为 `routel; true` 或干脆分开两条命令。
12. **路由规划与 step8 文档自相矛盾（除 #1 外的第二层不一致）**：`step8_traceroute_routes.sh:14-18` 与解读文本宣称 H56A→H57B 路径为 `RB→RA→RC→RE`，而 `create_topology.sh:187` 把 `57.128/26` 指向 RA–**RD** 链路的 `.254`。即便 #1 修复成"via 对端"，照 L187 原意（RD）路径会变成 `RB→RA→RD→RE`，与 step8 的"途经路由器"清单和路由表打印对象对不上。需二选一：路由改经 RC，或改 step8 的 `TARGETS`。
13. **拓扑偏离指导书**：指导书要求 RA 通过点对点链路连**主命名空间**的虚拟接口 `192.168.99.1/24`，脚本改用独立 `GW` 命名空间模拟（L25、L58）。README 有说明，属未声明的方案变更，实验报告引用指导书原文时会对不上。

## 🟡 小问题

14. **MTU 1000 低于 IPv6 最小 MTU 1280**（`step3_set_mtu.sh`）：veth 允许设 1000，但该链路上 IPv6（链路本地地址）将无法正常工作。本实验纯 IPv4 不受影响，属潜在坑；建议脚本输出一句警告，避免复用本拓扑做 IPv6 测试时误判为拓扑故障。
15. **netns 存在性检查用子串匹配**：`step3_set_mtu.sh:16`、`step6:21`、`step8:11` 的 `ip netns list | grep -q "$NS_RA"` 会把 `TRACE`、`RA2` 等误判为存在。应 `grep -qE "^$NS_RA\\b"` 或 `awk '{print $1}' | grep -qx`。
16. **`create_topology.sh:80` 与 `README.md:27` 均写"13 对 VETH"，实际创建了 14 对**（H56A、RB-56A、RB-RA、RC-RA、RD-RA、RA-GW、RC-57A、RE-57A、H57A、RE-57B、H57B、RD-57C、RE-57C、H57C）。
17. **`create_topology.sh` verify 在 `set -e` 下无容错**（L219-221）：任一 ping 失败脚本立即中断，后续验证项不再执行，也没有友好报错。
18. **`step8_traceroute_routes.sh:26`** `traceroute ... 2>/dev/null || true`：把 "Network unreachable" 等真实故障也静默成空输出，排查不便。
19. **`step6_ip_fragment.sh:29`** 服务端日志硬编码 `/tmp/exp6_server.log`，且从不检查 ncat 是否真的监听成功（端口被占则整个分片触发静默失败）。
20. **`step1_check_env.sh`**：`command -v wireshark` 在无 GUI 的宿主机上会直接判失败退出，虽然 tshark 已够用（指导书确实要求 wireshark，算可辩护）；缺工具时的报错统一打印 "（nping/ncat 属 nmap 包）"，对 wireshark/traceroute 有误导；`modinfo veth/bridge` 对内建模块会静默无输出。
21. **`step7_analyze_fragment.sh:16/22`** `-Y "ip"` 未按实验流（如 `udp.port==4499`）过滤，若拓扑上有其他 IP 流量会混入分析输出。

## 结论

**实验6 不可用**：`create_topology.sh` 的下一跳地址写反导致 `create` 在 `set -e` 下必然中途失败（这是比实验1同类问题更严重的原理性错误），`step3_set_mtu.sh` 又因未定义变量必崩；即便修复这两处，分片长度/偏移的错误文档（996≠1000、976≠122）会误导实验分析，抓包链路还缺乏失败可见性。修复优先级：路由下一跳 → `NS_H56A` → 分片文档 → bridge link/pcap 健壮性。
