# YashanDB 实时性能监控小工具 - 技术方案设计

目标：类似 Oracle oratop，在终端中实时展示 YashanDB 的 v$sysstat 指标（每秒变化量）和 v$system_event TOP 5 等待事件，支持跨平台并便于后续扩展。

---

## 一、功能需求摘要

| 模块 | 内容 |
|------|------|
| **v$sysstat** | 指定 14 项指标，按「每秒变化量」展示，每指标一行 |
| **v$system_event** | 按间隔内等待时间 TOP 5 排序展示 |
| **会话级指标 TOP N** | 基于 v$sesstat + v$statname，按指定统计项排序取 TOP N 个会话；默认按 DB TIME 排序，排序列与 TOP 行数可通过参数配置 |
| **TOP 会话详细信息** | 展示当前活跃会话的详细信息（sid_tid、event、username、sql_id、exec_time、program、client），按执行时间降序取 TOP N，便于排查长事务/长 SQL |
| **刷新** | 刷新间隔可自定义（默认如 1 秒），终端内原地刷新（TUI） |
| **执行次数** | 可指定采样次数（类似 iostat 的 `interval [count]`），执行满次数后自动退出；不指定则持续运行 |
| **输出到文件** | 支持将每轮显示内容追加写入指定文件，便于事后查看、审计或排查 |
| **扩展** | 后续可增加多屏、当前 SQL 等（类似 oratop） |

---

## 二、连接方式（Connector 需求）

数据库访问通过 **yasql** 命令行执行 SQL，支持本地与 SSH 中转两种方式；Connector 层统一抽象为「执行 SQL，返回可解析的文本结果」。

### 2.1 本地连接

- **方式 A**：`yasql / as sysdba`  
  - 以操作系统用户直连，无需输入密码（当前 OS 用户需有相应权限）。
- **方式 B**：`yasql` 启动后输入 **sys** 用户及密码（交互式），或通过脚本/配置传入 `sys/password`，由工具在调用 yasql 时通过 stdin 或 `-e` 等方式传入（具体以 yasql 是否支持非交互传参为准）。

实现要点：在本地用 **`os/exec`** 调用 `yasql`，将 SQL 通过 stdin 或命令行参数传入，从 stdout 解析表格输出（固定列宽或 CSV，需根据 yasql 实际输出格式解析）。

### 2.2 SSH 中转连接

- **步骤**：先 **SSH 登录到跳板机**，在跳板机上执行 yasql。
- **环境变量**：登录后、执行 yasql 前，可能需要执行 `source /path/to/env.sh`（或 `source ~/.bashrc` 等）以设置 YashanDB 相关环境变量（如 `PATH`、`LD_LIBRARY_PATH` 等），再执行 yasql。
- **连接形式**（在跳板机上）：  
  - `yasql / as sysdba`  
  - 或 `yasql sys/password@ip:port`（连接远程库的 ip:port）

实现要点：

- 使用 **`golang.org/x/crypto/ssh`** 建立 SSH 会话。
- 在 SSH 会话中依次执行：  
  `source <用户配置的脚本或 profile>` → `yasql ...`，将本轮要执行的 SQL 通过 stdin 传入 yasql，从 stdout 读取结果并解析。
- 为减少延迟，可复用同一 SSH 连接与同一 yasql 进程（若 yasql 支持会话内多次执行 SQL），或每轮新开 yasql 进程（实现更简单，延迟略高）。

### 2.3 配置项建议

| 配置项 | 说明 |
|--------|------|
| **connection_mode** | `local` \| `ssh` |
| **yasql_path** | 本地或跳板机上 yasql 可执行文件路径（可选，默认 `yasql`） |
| **connect_string** | `"/ as sysdba"` 或 `"sys/password"` 或 `"sys/password@ip:port"` |
| **ssh_host** | 跳板机 host（connection_mode=ssh 时必填） |
| **ssh_user** | SSH 登录用户 |
| **ssh_key_file** / **ssh_password** | SSH 认证方式 |
| **source_cmd** | 登录后执行的 source 命令，如 `source /opt/yashandb/conf/yasdb.env`（可选） |
| **interval** | 刷新间隔（秒），默认 1 |
| **count** | 执行次数，不设或 0 表示持续运行 |
| **output_file** | 每轮展示内容追加写入的文件路径（可选） |
| **session_top_n** | 会话 TOP 行数，默认如 10 |
| **session_sort_by** | 会话排序依据的统计项名，默认 `DB TIME`（须为下述会话指标之一） |
| **session_detail_top_n** | TOP 会话详细信息展示行数，默认如 10 |

Collector 只依赖 Connector 提供的「执行 SQL → 返回行数据」接口，不关心底层是本地 yasql 还是 SSH 上的 yasql。

### 2.4 运行参数（类似 iostat）

| 参数 | 说明 | 示例 |
|------|------|------|
| **刷新间隔** | 相邻两次采样的间隔秒数，可配置 | 默认 1；`-i 2` 表示每 2 秒一次 |
| **执行次数** | 采样轮数，执行满后自动退出；不指定则一直运行 | `-c 10` 或位置参数 `1 10` 表示间隔 1 秒、共 10 次 |
| **输出文件** | 将每轮展示的文本（与终端一致或简化）追加写入文件 | `-o /path/to/capture.log` 或 `--output capture.log` |
| **会话 TOP 行数** | 会话级指标展示的行数 | `--session-top 20` 表示 TOP 20 会话 |
| **会话排序列** | 会话按哪个统计项排序（降序） | `--session-sort "DB TIME"`（默认）；可选如 `CPU TIME`、`BUFFER GETS` 等 |
| **会话详情 TOP 行数** | 会话详细信息表展示的行数 | `--session-detail-top 15` 表示 TOP 15 条 |

**CLI 用法示例**（具体以实现为准）：

- `yashandb-monitor` — 默认 1 秒间隔，持续运行  
- `yashandb-monitor 2` — 每 2 秒刷新，持续运行  
- `yashandb-monitor 1 20` — 每 1 秒刷新，共 20 次后退出（类似 `iostat 1 20`）  
- `yashandb-monitor -o monitor.log` — 同时将每轮内容追加写入 `monitor.log`  
- 上述参数也可通过配置文件指定（如 `interval`、`count`、`output_file`），命令行可覆盖配置文件。

---

## 三、技术选型（Go）

### 3.1 选型：**Go + TUI 库 + yasql（本地/SSH）**

| 层次 | 选型 | 理由 |
|------|------|------|
| **语言** | Go 1.19+ | 单二进制分发、无需目标机装运行时；交叉编译一次可出多平台；适合 CLI/运维工具 |
| **DB 连接** | **yasql 命令行**（本地 `os/exec` 或 SSH 上执行） | 满足「yasql / as sysdba」与「sys/密码」及 SSH 中转 + source 环境；不依赖 YashanDB Go 驱动 |
| **SSH** | **golang.org/x/crypto/ssh** | 标准库风格，用于登录跳板机并执行 source + yasql |
| **终端 UI** | **bubbletea** 或 **tview** | 做 oratop 式单屏、定时刷新与表格展示足够；后续可扩展多屏/按键切换 |
| **定时/循环** | `time.Ticker` 或 TUI 自带更新周期 | 与主循环或 TUI 的 Update 结合即可 |

**备选**：若后续需要直连库（不经过 yasql），可再增加 YashanDB Go 驱动或通过 CGO 调用 C API 作为另一种 Connector 实现。

### 3.2 其他方案（不采用）

- **纯 Java + Lanterna**：与 YashanDB JDBC 天然契合，但打包、依赖较重；可作为后续「企业版/安装包」方案。

---

## 四、整体架构（分模块，便于扩展）

```
┌─────────────────────────────────────────────────────────┐
│         Main Loop（可配置周期 + 可配置执行次数）            │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Connector     │───▶│   Collector      │───▶│   Calculator    │
│ (YashanDB 连接)  │    │ (v$sysstat /     │    │ (每秒增量、      │
│                 │    │  v$system_event/ │    │  event TOP5、   │
│                 │    │  v$sesstat+statname)│  │  会话 TOP N)   │
└─────────────────┘    └──────────────────┘    └────────┬────────┘
                                                         │
                                                         ▼
                                                ┌─────────────────┐
                                                │   Display       │
                                                │ (TUI 刷新 /     │
                                                │  Table/Panel)    │
                                                └─────────────────┘
```

- **Connector**：封装「本地 yasql」与「SSH 上执行 source + yasql」两种方式，对外统一为「执行 SQL 并返回可解析的文本结果」；接口抽象便于以后加 JDBC/ODBC 直连。
- **Collector**：每轮执行四类 SQL：v$sysstat（指定 name 列表）、v$system_event（按等待时间取前 5）、v$sesstat 与 v$statname 关联（会话级指定统计项）、**会话详细信息**（session + process + 执行时间等），返回原始行。
- **Calculator**：对 v$sysstat 保存上一轮取值，算「当前值 − 上一轮」得到间隔内增量，再除以间隔秒数得到「每秒变化量」；对 v$system_event 做 TOP 5 排序；对会话级数据按用户指定列（默认 DB TIME）排序并取 TOP N；会话详细信息 SQL 已按执行时间降序，取前 N 行即可。
- **Display**：用 TUI 库（bubbletea/tview）在终端内刷新，布局分块：标题、sysstat 表、TOP 5 等待事件表、会话级指标 TOP N 表、**TOP 会话详细信息表**；若指定了输出文件，每轮刷新时同时将当前屏内容（文本形式）追加写入该文件，便于后期查看。

这样后续加「会话列表」「当前 SQL」等，只需新增 Collector/Calculator 模块和 Display 的一块区域（或新页面）。

---

## 五、数据与展示设计

### 5.1 v$sysstat 每秒变化量

- **采样**：每轮（如每 1 秒）查一次你给出的 14 个 name 的当前统计值。
- **计算**：`delta_per_sec = (value_cur - value_prev) / interval_sec`，其中 `interval_sec` 为与上一轮的时间差（建议用实际时间差，避免漂移）。
- **展示**：表格三列即可，例如：**指标名** | **当前值** | **每秒变化**；每指标一行。

若 YashanDB 的 v$sysstat 与 Oracle 类似（累计值），上述做法即「每秒变化率」；若为瞬时值则需按文档再定。

### 5.2 v$system_event TOP 5

- **查询**：按「等待时间」排序（具体列名以 YashanDB 文档为准，如 `total_waits`、`time_waited` 等），取前 5。
- **间隔内 TOP 5**：若视图是累计值，则需两次快照做差再排序（与 sysstat 同一轮里查两次，或用上一次快照与本次做差），得到「本间隔内」的 TOP 5 等待事件。
- **展示**：表格列如：**事件名** | **总等待次数** | **等待时间** | **占比**（可选），一行一个事件，共 5 行。

### 5.3 会话级指标 TOP N（v$sesstat + v$statname）

- **数据来源**：关联 **v$sesstat** 与 **v$statname**，按统计项名称过滤出以下 14 项（与 sysstat 同名的会话级统计）：
  - `DB TIME`, `CPU TIME`, `COMMITS`, `REDO SIZE`, `QUERY COUNT`, `BLOCK CHANGES`, `LOGONS TOTAL`, `INSERT COUNT`, `PARSE COUNT (HARD)`, `DISK READS`, `DISK WRITES`, `BUFFER GETS`, `EXECUTE COUNT`, `BUFFER CR GETS`
- **查询思路**：通过 v$statname 中 name 与上述列表匹配得到 statistic#，再与 v$sesstat（sid + statistic# + value）关联，按会话聚合或按需 pivot；按用户指定的排序列（默认 **DB TIME**）降序排序，取前 N 行（N 由参数指定，默认如 10）。
- **参数**：**排序列**（`session_sort_by`，默认 `DB TIME`）与 **TOP 行数**（`session_top_n`，默认如 10）均可通过 CLI 或配置文件指定。
- **展示**：表格列包含会话标识（如 SID、SERIAL#、USERNAME 等，以 YashanDB 文档为准）、以及上述 14 项中的全部或关键列；至少包含排序列，便于核对。一行一个会话，共 N 行。

### 5.4 TOP 会话详细信息

- **目的**：展示当前活跃会话的详细信息，便于排查长事务、长 SQL 和等待事件；按「当前执行时长」降序，取 TOP N 条。
- **展示列**：**sid_tid**（实例.sid.serial#.thread_id）、**event**（当前等待事件，截断）、**username**、**sql_id**、**exec_time**（执行时长，格式化为 MS/S/KS/WS）、**program**（客户端程序，截断）、**client**（ip.port）。
- **数据来源**：关联会话视图与进程视图（Oracle 示例为 gv$session、gv$process、v$SQLCOMMAND）；过滤 `TYPE NOT IN ('BACKGROUND')`、`status NOT IN ('INACTIVE')`；按 `exec_seconds`（从 exec_start_time 到当前时间的秒数）降序，取前 N 行。YashanDB 若为单实例，可能使用 v$session/v$process，视图名与日期函数需按官方文档适配。
- **参考 SQL（Oracle 风格，需按 YashanDB 视图/列名与日期函数改写）**：

```sql
SELECT
    sid_tid,
    event,
    username,
    sql_id,
    CASE
        WHEN exec_seconds < 1 THEN ROUND(exec_seconds * 1000, 0) || 'MS'
        WHEN exec_seconds < 1000 THEN ROUND(exec_seconds, 2) || 'S'
        WHEN exec_seconds < 10000 THEN ROUND(exec_seconds / 1000, 2) || 'KS'
        ELSE ROUND(exec_seconds / 10000, 2) || 'WS'
    END AS exec_time,
    program,
    client
FROM (
    SELECT
        a.inst_id||'.'||a.sid||'.'||a.serial#||'.'||b.thread_id AS sid_tid,
        substr(a.wait_event,1,30) AS event,
        a.username AS username,
        substr(a.cli_program,1,30) AS program,
        substr(c.command_name,1,3)||'.'||nvl(a.sql_id,a.sql_id) AS sql_id,
        EXTRACT(DAY FROM (sysdate-a.exec_start_time)) * 86400 +
        EXTRACT(HOUR FROM (sysdate-a.exec_start_time)) * 3600 +
        EXTRACT(MINUTE FROM (sysdate-a.exec_start_time)) * 60 +
        EXTRACT(SECOND FROM (sysdate-a.exec_start_time)) AS exec_seconds,
        a.ip_address||'.'||a.ip_port AS client
    FROM gv$session a, gv$process b, v$SQLCOMMAND c
    WHERE a.inst_id = b.inst_id
      AND a.paddr = b.thread_addr
      AND a.command = c.command_type(+)
      AND a.TYPE NOT IN ('BACKGROUND')
      AND a.status NOT IN ('INACTIVE')
    ORDER BY exec_seconds DESC
)
-- 外层再取前 N 行（或数据库侧 ROWNUM/LIMIT）
```

- **参数**：展示行数 **session_detail_top_n**（默认如 10），可通过配置文件或 `--session-detail-top` 指定。

### 5.5 界面布局（oratop 风格）

- **顶部**：标题、YashanDB 连接串/实例名、当前时间、刷新间隔；若指定了执行次数，可显示「第 n / 共 N 次」。
- **中部 1**：v$sysstat 表格（14 行，指标名 + 当前值 + 每秒变化）。
- **中部 2**：v$system_event TOP 5 表格。
- **中部 3**：会话级指标 TOP N 表格（排序列与 N 由参数指定，默认按 DB TIME、TOP 10）。
- **中部 4**：TOP 会话详细信息表（sid_tid、event、username、sql_id、exec_time、program、client），行数由 session_detail_top_n 指定。
- **底部**：按键说明（如 q 退出、s 暂停、1/2 切换页面等，为后续扩展预留）；若启用了输出文件，可提示「输出: xxx.log」。

---

## 六、跨平台与依赖

- **语言与构建**：Go 1.19+，`go build` 即得单二进制；交叉编译可一次产出 Linux/Windows/macOS 等，目标机无需安装 Go 或任何运行时。
- **依赖**（Go modules）：  
  - **golang.org/x/crypto/ssh**（SSH 连接跳板机）  
  - TUI：**github.com/charmbracelet/bubbletea** 或 **github.com/rivo/tview**  
  - 无需 YashanDB 驱动：通过本地 `os/exec` 或 SSH 上的 **yasql** 执行 SQL，解析 stdout 输出。
- **配置**：连接方式（local/ssh）、yasql 连接串、SSH 主机/用户/source 命令、**刷新间隔**、**执行次数**、**输出文件路径**等，从配置文件或环境变量读取（如 `~/.yashandb-monitor.conf`），命令行参数可覆盖，避免写死在代码里。

### 6.1 分发

**单二进制**即可：`go build -o yashandb-monitor ./cmd/yashandb-monitor`，拷贝到目标机即可运行。目标环境仍需能执行 **yasql**（本机或 SSH 对端）；本工具不内嵌 YashanDB 客户端，仅调用系统/跳板机上的 yasql。若需“解压即用”，可在同一安装包内附带 yasql 或提供安装说明。

---

## 七、项目结构建议（便于后续扩展）

```
yashandb-monitor/
├── README.md
├── go.mod
├── go.sum
├── config.example.ini       # 连接与刷新间隔示例
├── cmd/
│   └── yashandb-monitor/
│       └── main.go          # 入口：解析参数、初始化连接与 TUI、启动主循环
├── internal/
│   ├── connector/
│   │   ├── interface.go     # 抽象：ExecuteSQL(sql) -> 行数据
│   │   ├── local.go         # 本地 os/exec 调用 yasql
│   │   └── ssh.go           # golang.org/x/crypto/ssh + source + yasql
│   ├── collector/
│   │   ├── sysstat.go       # 采集 v$sysstat
│   │   ├── system_event.go  # 采集 v$system_event
│   │   ├── sesstat.go       # 采集 v$sesstat + v$statname（会话级）
│   │   └── session_detail.go # 采集 TOP 会话详细信息（session+process+exec_time）
│   ├── calculator/
│   │   ├── sysstat_delta.go # 计算每秒增量
│   │   ├── top_events.go    # TOP 5 排序
│   │   └── session_top.go    # 会话按指定列 TOP N 排序
│   └── display/
│       └── tui.go           # TUI 刷新 + 表格/面板 组装
```

后续可加：`collector/session.go`、`display/session_screen.go`、多屏切换等，与 oratop 对齐。

---

## 八、实现顺序建议

1. **Connector**：实现本地 yasql（`/ as sysdba` 或 sys/密码）与 SSH 中转（source + yasql）；统一解析 yasql 的 stdout 为行数据；执行 v$sysstat、v$system_event、v$sesstat+v$statname、**会话详细信息** SQL，确认列名与输出格式。
2. **Calculator**：实现「上一轮/本轮」两次 sysstat 快照做差并除以时间间隔；实现 event TOP 5 排序；实现会话级按指定列（默认 DB TIME）TOP N 排序；会话详细信息直接取查询结果前 N 行。
3. **Display**：用 TUI 库画出固定布局（sysstat 表、event TOP 5 表、会话 TOP N 表、**TOP 会话详细信息表**），按配置间隔更新数据并刷新。
4. **Main**：按配置的间隔循环：采集 → 计算 → 更新展示；若指定了执行次数，达到次数后自动退出；处理 Ctrl+C 和 q 退出；若指定了输出文件，每轮将当前展示内容（纯文本）追加写入该文件。
5. **配置与参数**：连接信息、刷新间隔（interval）、执行次数（count）、输出文件（output_file）、会话 TOP 行数（session_top_n）、会话排序列（session_sort_by）、**会话详情 TOP 行数（session_detail_top_n）**；CLI 支持 `interval [count]`、`-o/--output`、`--session-top`、`--session-sort`、`--session-detail-top`，与配置文件可叠加、命令行优先。

---

## 九、与 Oracle oratop 的对照

| oratop 能力 | 本工具对应 |
|-------------|------------|
| 头部实例/运行时间/内存/CPU | 首屏标题区：连接信息、刷新间隔 |
| DB 区多实例/参数 | 当前可为单实例，预留多实例扩展 |
| Top 等待事件 | v$system_event TOP 5 |
| 进程/会话区 | 会话级指标 TOP N（v$sesstat + v$statname）+ TOP 会话详细信息（sid_tid、event、sql_id、exec_time、program、client） |
| 按键切换/多屏 | 后续用 TUI 库多 Layout 或多屏切换 |

先实现「单屏：sysstat 每秒变化 + TOP 5 等待」，再按需加会话、SQL、多实例等，逐步向 oratop 看齐。

---

## 十、注意事项

- **v$system_event 列名**：需对照 YashanDB 官方文档确认（如 `event`、`total_waits`、`time_waited` 等），与 Oracle 可能略有差异。
- **v$sesstat / v$statname 列名**：需对照 YashanDB 文档确认（如 sid、statistic#、value、name 等），以及会话标识、用户名等来自 v$session 的关联方式（若需展示 USERNAME 等）。
- **会话详细信息视图**：参考 SQL 使用 gv$session、gv$process、v$SQLCOMMAND（Oracle）；YashanDB 单实例可能为 v$session、v$process，列名（如 wait_event、exec_start_time、cli_program、command_type）及日期函数需按官方文档适配。
- **权限**：运行用户需能查询 `v$sysstat`、`v$system_event`、`v$sesstat`、`v$statname`、会话/进程相关视图（如 v$session、v$process）及 v$SQLCOMMAND（或等价）（通常为 DBA 或只读监控账号）。
- **刷新间隔与执行次数**：建议默认间隔 1 秒、不限制次数（持续运行）；可配置间隔与次数，便于像 iostat 一样做「采 N 次后退出」；过短会增加库负载，过长则不够「实时」。
- **输出文件**：写入时建议每轮带时间戳或分隔线，便于区分不同采样时刻；文件可轮转或由用户自行管理，避免单文件过大。

若你提供 YashanDB 的 v$sysstat / v$system_event 文档或示例查询结果，可以再细化 SQL 与列映射，并写一版最小可运行的 `cmd/yashandb-monitor` + `internal/connector` + `internal/display` 示例代码。
