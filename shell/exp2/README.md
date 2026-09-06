# 实验2 脚本说明

对应指导书《实验2：HTTP协议探索与分析》各步骤的一键化脚本。
实验拓扑：本机（客户机）→ 互联网 → 公网 Web 服务器 `www.zzu.edu.cn`。
需要**公网访问**；抓包脚本需 **sudo**，且浏览器与抓包在同一终端会话（共享 `SSLKEYLOGFILE`）。

## 脚本清单与执行顺序

| 顺序 | 脚本 | 对应步骤 | 作用 |
|---|---|---|---|
| 1 | `step1_check_env.sh` | 步骤1 环境检查 | 工具检查、DNS A/AAAA 解析、IPv4/IPv6 可达性、出口接口探测 |
| 2 | `step2_tls_capture.sh` | 步骤2 TLS密钥日志+抓包 | **核心自动化脚本**：SSLKEYLOGFILE → Firefox → tshark 抓包 → 自动解密验证 |
| 3 | `step3_filter_trace.sh` | 步骤3 过滤/追踪HTTP流 | 提取 IPv4_zzu/IPv6_zzu、过滤服务器流量、追踪 HTTP 流 |
| 4 | `step4_cookie.sh` | 步骤4 Cookie 分析 | 过滤 set_cookie/cookie 首部行并解析字段 |
| 5 | `step5_tcp_sessions.sh` | 步骤5 TCP并发连接数 | TCP 会话统计（等价 GUI 统计→会话→TCP） |

## 快速开始

```bash
cd shell/exp2
chmod +x *.sh

./step1_check_env.sh                      # 无需 root
sudo ./step2_tls_capture.sh 15            # 抓包 15 秒，生成 exp2_https.pcap + myssl.log
./step3_filter_trace.sh                   # 后续分析直接读 pcap
./step4_cookie.sh
./step5_tcp_sessions.sh
```

## 预期实验现象（汇总）

1. **步骤1**：`www.zzu.edu.cn` 解析出 2 个 IPv4（202.196.64.194/48）+ 2 个 IPv6（2001:da8:5000:6c00::48/47）地址；Firefox `about:networking#dnslookuptool` 中排在前面的协议即浏览器优先协议；IPv4 HTTPS 返回 `HTTP/2 200`。
2. **步骤2**：`myssl.log` 生成且非空（每行一条 `CLIENT_HANDSHAKE_TRAFFIC_SECRET ...` 密钥记录）；tshark 用 `tls.keylog_file` 解密后列出明文 HTTP 请求（`http.host=www.zzu.edu.cn`、`GET`）——等价于指导书 GUI 配置密钥后"TLS 自动变明文"的现象。
3. **步骤3**：得到 `IPv4_zzu`/`IPv6_zzu`；追踪 HTTP 流可见完整请求/响应报文（请求行/状态行 + 首部行 + 空行 + 实体）。
4. **步骤4**：响应含 `Set-Cookie: 名称=值; expires=...; path=/; HttpOnly`，后续请求自动回带 `Cookie: 名称=值`——体现 HTTP 会话保持机制。
5. **步骤5**：浏览器并发建立多条 TCP 连接（不同本地临时端口，HTTP/1.1 通常约 6 条，HTTP/2 较少），用于并行加载页面资源。

## 与指导书 GUI 操作的对应关系

| 指导书 GUI 操作 | 脚本等价实现 |
|---|---|
| Wireshark 选接口开始捕获 | `tshark -i <出口接口> -w exp2_https.pcap` |
| 首选项→Protocols→TLS→密钥日志文件 | `tshark -o tls.keylog_file:myssl.log` |
| 显示过滤器 `http.host == www.zzu.edu.cn` | `-Y "http.host == ..."` |
| 右键→追踪流→HTTP Stream | `-q -z follow,tcp,ascii,<流号>` |
| 统计→会话→TCP 标签页 | `-q -z conv,tcp,<过滤>` |

## 注意事项

- **必须先关闭已运行的 Firefox** 再跑步骤2，否则旧实例不读取新的 `SSLKEYLOGFILE`（脚本已用独立 profile + `--no-remote` 规避，但仍建议关闭旧实例）。
- 若站点未使用 Cookie 或抓包太短，步骤4 可能无输出，可重跑步骤2 并在 Firefox 中多点击几个页面。
- IPv6 不可达的网络属"IPv4 单栈场景"，步骤1 中 IPv6 测试失败是正常现象。
