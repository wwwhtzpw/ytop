>我们的文章会在微信公众号[IT民工的龙马人生](https://mp.weixin.qq.com/s/Gkmr9MArgh_4vMXhVvQULA)和[博客网站](http://www.htz.pw) ( www.htz.pw )同步更新 ，欢迎关注收藏，也欢迎大家转载，但是请在文章开始地方标注文章出处，谢谢！
>由于博客中有大量代码，通过页面浏览效果更佳。



## 摘要
性能问题的难点从来不在“有没有指标”，而在“能否在现场、在最短时间内，把系统负载、等待瓶颈、会话 TOP与SQL现场串起来”。**ytop**是一款面向**YashanDB**的终端实时性能监控工具，交互体验类似 Oracle的oratop和Linux的top的结合：持续采样、增量计算、TOP 视图、会话明细一屏联动，并提供脚本化能力把DBA经验沉淀为可复用工具链。本文从设计理念、实时监控界面、使用案例、脚本能力清单、子命令（sesstat/sesevent）与参数帮助六个角度，系统介绍 ytop 的落地方式。

---

## 1）为什么 DBA 需要 ytop：把“排障闭环”固化下来
在真实生产环境里，性能问题往往具备三个特征：

- **窗口短**：抖动可能持续几十秒到几分钟，错过现场就只能事后“猜”。
- **信息碎**：系统指标在一处、等待在一处、会话在一处、SQL/对象在一处，需要反复切换。
- **链路复杂**：远程主机、跳板机、环境变量、权限与工具版本差异，都会拖慢定位速度。

DBA 的理想工作流其实很明确：  
**系统负载 → 等待方向 → 会话TOP → 会话/SQL明细 → 处置建议**。  
ytop 的设计目标就是把这条链路产品化，降低“现场拼 SQL”的成本，把时间留给真正的判断与决策。

---

## 2）ytop 是什么：设计理念与架构
ytop 是一款面向 **YashanDB** 的实时性能监控 CLI。它采用“**外部 yasql**”的数据库访问方式，而不是嵌入驱动，带来两个直接收益：

- **交付轻**：Go 单二进制，部署简化；
- **适配强**：环境只要能执行 `yasql`（本机或 SSH 远程），就能采集监控数据。支持本地认证，也支持远程登录数据库。

架构上，ytop 保持模块清晰、便于扩展：

- **Connector**：本地/SSH 两种连接模式（通过 `yasql`）
- **Collector**：采集系统与会话相关视图数据（gv$ / AWR 等）
- **Calculator**：做快照间 delta、每秒速率、TOP N 排序
- **Display**：终端 TUI 持续刷新输出（面板化展示）

---

## 3）快速上手：安装与运行
ytop 以单二进制分发。常见使用方式如下（示例）：

### 3.1 监控模式（默认）

```bash
ytop
```

### 3.2 指定采样间隔与采样次数

```bash
ytop 2        # 2 秒采样，默认 5 次
ytop 1 20     # 1 秒采样，共 20 次
```

### 3.3 SSH 远程模式（示例）

```bash
ytop -h 10.10.10.130 -u yashan -p oracle -s "source ~/.bashrc"
```

---

## 4）实时监控界面：一屏完成“现象 → 现场 → 动作”
ytop 的实时监控界面不是“堆指标”，而是围绕 DBA 的决策路径组织信息。你可以把它理解为一个固定节奏的排障面板：

- **System（系统指标 / v$sysstat）**
  - 用于判断整体负载是否异常、是否出现突刺、吞吐是否变化
  - 关键计数类指标按采样间隔做 delta/每秒速率，更贴近“实时判断”的需求

- **Top Waits（系统等待 TOP / v$system_event 等）**
  - 用于快速确认瓶颈方向：IO、锁、网络、日志同步等
  - 适合“方向判断”与“优先级排序”

- **Session TOP（会话指标 TOP / v$sesstat + v$statname 等）**
  - 用于锁定“谁在消耗”（按 DB TIME、CPU TIME 等）
  - 适合从系统层面下钻到会话层面

- **Session Details（活跃会话明细）**
  - 用于把问题落到具体会话：sid/tid、username、event、sql_id、exec_time、program、client 等
  - 适合形成处置动作：找责任方、找 SQL、判断是否 kill、是否需要限流/变更

### 4.1 实时监控界面下的功能键（快捷键）
在监控界面内，ytop 内置了“现场工具箱式”的快捷操作：

- **`a`**：Ad-hoc SQL（输入并执行一条临时 SQL）
- **`s`**：Script/Cmd（执行 SQL 脚本或 OS 命令）
- **`f`**：Find（按正则搜索脚本，`.*` 表示全部）
- **`r`**：Read（查看脚本内容）
- **`c`**：Copy（复制脚本到本地或远端目录）
- **`h`**：Help（显示交互帮助）
- **`q` / `ESC`**：Quit（退出）

> 说明：`s` 是 DBA 的统一入口：SQL 脚本（`.sql`）与 OS 命令（非 `.sql`）都从这里触发，适合把“实时面板观察”与“脚本化诊断/处置”连成一个闭环。

### 4.2 `s`（Script/Cmd）模式的输入规则（路径 vs 脚本名）
`s` 模式中输入会按以下逻辑解释：

- **SQL 脚本**：输入以 `.sql` 结尾的内容
  - **脚本名**：如 `we.sql`，从脚本库查找（内嵌或外置 `scripts/sql/`）
  - **显式路径**：如 `./we.sql`、`/path/to/we.sql`、`D:\path\to\we.sql`，直接从操作系统读取
  - 若脚本包含 `&var` / `&&var` 会提示输入；**直接回车**表示空字符串（适用于“不填即不过滤/走默认”）

- **OS 命令**：不以 `.sql` 结尾的内容
  - 本地模式：本机执行
  - SSH 模式：远端执行（如 `iostat -x 1 2`）

---

## 5）实时监控使用案例（从“看面板”到“落动作”）
下面给出两类 DBA 高频现场的使用范式，你可以把它当作“工具使用方法论”。

### 案例 A：突发变慢，怀疑锁等待（TX / 行锁链路）
**现象**：业务反馈“突然变慢/卡住”，且症状集中在一段时间窗口。

**用 ytop 的步骤**：
1. **看 Top Waits**  
   若锁相关等待显著抬头（TX/行锁类事件），优先进入锁链路确认。
2. **看 Session TOP / Session Details**  
   找到 exec_time 很长、等待事件明显的会话，记录 `sid/tid`、`username`、`sql_id`、`program/client`。
3. **按 `s` 执行锁树脚本**  
   - `lock_tx_tree.sql`（事务锁树）
   - 或 `lock_tree.sql`（行锁/表锁树）
4. **处置建议**  
   - 阻塞链路清晰：先定位 blocker 的来源（client/program/user），与业务确认；
   - 需要强制处置：再使用 `kill_sess_by_where.sql`（务必先过滤、先验证，谨慎执行）。

### 案例 B：CPU 飙升/吞吐下降，怀疑 TOP SQL 爆发（历史与当下结合）
**现象**：CPU 突刺或持续偏高，吞吐下降，系统层面指标异常明显。

**用 ytop 的步骤**：
1. **看 System 指标**：观察与 CPU/逻辑读/物理读/解析相关指标的变化速率。
2. **看 Session TOP**：锁定消耗最大的会话，记录 `sql_id`、`username`、`program/client`。
3. **按 `s` 执行 SQL 定位脚本**：
   - `find_sql.sql`：按 SQL 文本片段查 SQL_ID
   - `sql_by_sqlid.sql`：按 SQL_ID 输出 SQL 全文
4. **结合 AWR 做“最近一天 TOP SQL”**：
   - `awr_top_sql_last_day_opt.sql`（或 `awr_top_sql_last_day.sql`）
   用于确认该 SQL 是“持续热点”还是“短时异常”，并输出 SQL 文本/计划/对象信息，形成优化或回滚建议。

---

## 6）目前已编写/内置的 SQL 脚本清单（能力清单）
> 以下为当前仓库 `scripts/sql`、`scripts/os` 中的脚本能力（按主题归类）。

### A）AWR / 性能历史分析
- `awr.sql`：展示 AWR load profile 信息
- `awr_create.sql`：创建一次 AWR snapshot
- `awr_snapshot.sql`：查看 snapshot 时间与 DB time
- `awr_event_top5.sql`：AWR 等待事件 TOP5
- `awr_event_avg_time_trend.sql`：等待事件平均响应时间趋势（按天/小时，可按事件过滤）
- `awr_sql_by_cpu_by_day.sql`：按天 TOP SQL（CPU）
- `awr_sql_by_elapsed_by_day.sql`：按天 TOP SQL（DB Time/Elapsed）
- `awr_sql_by_buffer_gets_by_day.sql`：按天 TOP SQL（buffer gets）
- `awr_sql_by_disk_reads_by_day.sql`：按天 TOP SQL（disk reads）
- `awr_top_sql_last_day.sql`：最近一天 TOP SQL（CPU），输出 SQL 文本、执行计划、v$sql/v$sqlstats、涉及对象等（DBMS_OUTPUT 汇总）
- `awr_top_sql_last_day_opt.sql`：同上（优化版：对象信息一次性收集，减少重复计算）

### B）会话 / 等待 / 锁（现场排障高频）
- `we.sql`：会话信息展示
- `we_23.5.sql`：会话信息展示（版本适配变体）
- `lock_tree.sql`：行锁/表锁树（阻塞链路梳理）
- `lock_tx_tree.sql`：TX 锁树（事务锁阻塞链路）
- `kill_sess_by_where.sql`：按条件 kill session（快速处置）
- `sid_undo.sql`：会话事务/UNDO 使用信息（追踪大事务）
- `dump_sid.sql`：dump session backtrace 并返回 trace 文件路径
- `dump_block.sql`：dump datafile/block 范围并返回 trace 文件路径
- `mysid.sql`：查询当前会话 SID（脚本联动辅助）

### C）SQL 定位与调优辅助
- `find_sql.sql`：按 SQL 文本片段查 SQL_ID 与基础信息
- `sql_by_sqlid.sql`：按 SQL_ID 输出 SQL 全文
- `sql.sql`：SQL tuning 信息汇总脚本（偏全量诊断）

### D）对象/表/索引/约束/DDL 与容量核算
- `object.sql`：对象信息搜索/展示
- `table.sql`：表与索引、列等信息综合展示
- `table_column.sql`：表列信息
- `table_index.sql`：索引信息（类型/唯一性/表空间等）
- `ddl_table.sql`：获取表/索引/触发器等 DDL（DBMS_METADATA）
- `constraint_table.sql`：约束及列清单（含引用关系）
- `segment.sql`：segment 信息展示
- `table_size.sql`：表/LOB/索引大小核算
- `table_part_size.sql`：分区/子分区大小（含 LOB）核算
- `db_size.sql`：表空间使用率
- `datafile.sql`：数据文件/临时文件一览（支持变量过滤）
- `logfile.sql`：redo logfile 信息

### E）账号 / 权限
- `user.sql`：用户信息展示（状态/表空间/PROFILE/时间等）
- `user_all_priv.sql`：用户权限汇总（对象权限 + 角色链路）

### F）高可用 / 归档 / 复制（Standby）
- `arch_dest_status.sql`：归档目的端状态（v$archive_dest_status）
- `standby.sql`：恢复/复制状态汇总查询
- `standby_switch_max_perf.sql`：切换到 MAXIMIZE PERFORMANCE
- `standby_switch_max_avai.sql`：切换到 MAXIMIZE AVAILABILITY
- `standby_switch_max_prot.sql`：切换到 MAXIMIZE PROTECTION

### G）存储（YFS）
- `yfs_diskgroup.sql`：YFS diskgroup 使用率与状态
- `yfs_disk.sql`：YFS disk 明细（路径/冗余/使用率等）

### H）运维变更类（谨慎执行）
- `redo_add.sql`：redo logfile 增删改（按参数组数/大小/路径调整，含切换控制与安全检查）

### I）OS 脚本
- `iostat.sh`：iostat 包装示例脚本

---

## 7）sesstat / sesevent：会话统计与会话等待的“独立采样工具”
除了实时监控界面，ytop 还提供两个专门用于“按会话做采样对比”的子命令：`sesstat(stat)` 与 `sesevent(event)`。它们适合在不进入监控 UI 的情况下快速做 TOP N 分析或对指定 SID 做定点观测。

### 7.1 `ytop stat`（sesstat）：会话统计（v$sesstat）
**用途**：按采样做会话统计聚合，常用于定位 CPU、解析、逻辑读等统计项的“TOP 会话”或“指定会话的 TOP 统计项”。

**帮助信息（实际 `--help` 输出）**：

```text
ytop sesstat - Query session statistics

Usage:
  ytop sesstat|stat [global options] [stat options]

Stat-Specific Options:
  -S, --sid <sids>      Session ID filter (comma-separated, e.g., 40,50,90)
  -n, --stat <names>    Statistic name filter (comma-separated, supports % wildcard)

Behavior:
  - Without --sid: Shows TOP N sessions by total statistic value
  - With --sid: Shows TOP N statistics for specified sessions
  - Displays percentage contribution for all results
```

**常用示例**：
- 按统计值展示 TOP 会话（例如 TOP10）：
  - `ytop stat -h 10.10.10.130 -u yashan -p oracle -c 2 -t 10`
- 对指定会话看 TOP 统计项：
  - `ytop stat -h 10.10.10.130 -u yashan -p oracle -S 40,50 -t 10`
- 过滤统计项名称（支持 `%` 通配）：
  - `ytop stat -h 10.10.10.130 -u yashan -p oracle -n "CPU%,parse%" -S 40`

### 7.2 `ytop event`（sesevent）：会话等待事件（v$session_event）
**用途**：按采样做会话等待事件聚合，常用于定位“TOP 等待会话”或“指定会话的 TOP 等待事件”，并展示平均等待耗时与占比。

**帮助信息（实际 `--help` 输出）**：

```text
ytop sesevent - Query session events

Usage:
  ytop sesevent|event [global options] [event options]

Event-Specific Options:
  -S, --sid <sids>      Session ID filter (comma-separated, e.g., 40,50,90)
  -e, --event <names>   Event name filter (comma-separated, supports % wildcard)

Behavior:
  - Without --sid: Shows TOP N sessions by total wait time
  - With --sid: Shows TOP N events for specified sessions
  - Displays average wait time (ms) and percentage contribution
```

**常用示例**：
- 按等待时间展示 TOP 会话：
  - `ytop event -h 10.10.10.130 -u yashan -p oracle -c 2 -t 10`
- 对指定会话看 TOP 等待事件：
  - `ytop event -h 10.10.10.130 -u yashan -p oracle -S 40,50 -t 10`
- 过滤等待事件名称（支持 `%` 通配）：
  - `ytop event -h 10.10.10.130 -u yashan -p oracle -e "db%,log%" -S 40`

---

## 8）参数与帮助信息（--help 输出确认）
下面是 `ytop --help` 的实际输出（用于文档对齐程序行为）：

```text
ytop - Real-time performance monitoring tool for YashanDB

Usage:
  ytop [global options] [interval] [count]           # Monitor mode (default)
  ytop -f <script> [global options] [interval] [count] # Execute script directly
  ytop -q <sql> [global options] [interval] [count]    # Execute SQL directly
  ytop -r <script>                                 # Read script content
  ytop -c <script dest>                               # Copy script to destination
  ytop -S <pattern>                                    # Find scripts by pattern
  ytop sesstat|stat [global options] [stat options]  # Session statistics query
  ytop sesevent|event [global options] [event options] # Session events query
  ytop --help|help                                   # Show this help
  ytop --version|-v|version                          # Show version

Global Options:
  --config <file>       Path to config file
  --yasql <path>        Path to yasql executable (default: yasql)
  -C, --connect <string> Connection string (default: / as sysdba)
  -h, --host <host>     SSH host (if specified, use SSH mode; otherwise local mode)
  --port <port>         SSH port (default: 22)
  -u, --user <user>     SSH user
  -p, --password <pass> SSH password
  -k, --key <file>      SSH private key file
  -s, --source <cmd>    Source command to run before yasql
  -i, --interval <sec>  Interval in seconds (default: 5 for monitor, 0 for direct execution)
  -c, --count <num>     Number of samples/iterations (default: 5 for monitor, 1 for direct execution)
  -t, --top <num>       Number of top results to show (default: 5)
  -o, --output <file>   Output file path
  -I, --inst <id>       Instance ID (0 = all instances, default: 0)
  -d, --debug           Enable debug mode

Direct Execution Options:
  -f <script>           Execute script file (SQL or OS command) without entering monitor UI
                        Script can be: script name (e.g., we.sql) or full path
  -q <sql>              Execute SQL query directly without entering monitor UI
  -r <script>           Read/view script content without entering monitor UI
  --copy <script dest>  Copy script to destination (e.g., 'we.sql /tmp')
  -S <pattern>           Find/search scripts by pattern (supports regex)
```

---

## 9）ytop 对 DBA 的价值：从工具到方法论
从 DBA 视角，我认为 ytop 的价值可以落到三句话：

- **更快的定位闭环**：系统→等待→会话→SQL，把排障路径缩短到一个终端界面里完成
- **更可靠的现场观测**：持续采样 + 增量计算，减少“只看瞬时点”的误判
- **更强的经验复用**：脚本库内嵌交付 + 正则搜索 + 一键执行，把个人经验沉淀为团队能力

---

## 结语：把现场留给判断，把重复交给工具
性能问题的现场最宝贵的是 DBA 的判断力：你要辨别方向、确认证据链、评估风险并选择处置动作。ytop 的意义在于把重复劳动（采集、刷新、排序、脚本查找与执行）交给工具，把 DBA 从“执行器”解放为“决策者”。
