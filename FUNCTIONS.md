# yastop 模块函数参考手册

本文档列出了 yastop 项目中所有模块的已实现函数，方便后续开发时快速查找和调用。

---

## 1. connector 模块 - 数据库连接层

### connector/interface.go
定义了统一的连接器接口。

```go
type Connector interface {
    Connect(ctx context.Context) error
    ExecuteQuery(ctx context.Context, sql string) ([][]string, error)
    Close() error
    IsConnected() bool
}
```

### connector/local.go
本地 yasql 连接实现。

**函数列表**:
- `NewLocalConnector(cfg *config.Config) *LocalConnector` - 创建本地连接器
- `Connect(ctx context.Context) error` - 建立本地连接（验证 yasql 可用性）
- `ExecuteQuery(ctx context.Context, sql string) ([][]string, error)` - 执行 SQL 查询
- `Close() error` - 关闭连接
- `IsConnected() bool` - 返回连接状态

### connector/ssh.go
SSH 远程 yasql 连接实现。

**函数列表**:
- `NewSSHConnector(cfg *config.Config) *SSHConnector` - 创建 SSH 连接器
- `Connect(ctx context.Context) error` - 建立 SSH 连接并验证 yasql
- `ExecuteQuery(ctx context.Context, sql string) ([][]string, error)` - 通过 SSH 执行 SQL 查询
- `ExecuteCommand(ctx context.Context, command string) (string, error)` - 执行原始 shell 命令
- `Close() error` - 关闭 SSH 连接
- `IsConnected() bool` - 返回连接状态

### connector/parser.go
yasql 输出解析和错误检测。

**函数列表**:
- `parseYasqlOutput(output string) ([][]string, error)` - 解析 yasql 固定宽度列输出
- `parseFixedWidthLine(line string, colWidths []int) []string` - 解析单行固定宽度数据
- `checkYashanError(output string) error` - 检测 YAS-NNNNN 格式的数据库错误

---

## 2. collector 模块 - 数据收集层

### collector/collector.go
从 YashanDB 收集各类性能指标。

**函数列表**:
- `NewCollector(cfg *config.Config, conn connector.Connector) *Collector` - 创建收集器
- `CollectSysStats(ctx context.Context) ([]models.SysStatMetric, error)` - 收集 v$sysstat 系统统计指标
- `CollectSystemEvents(ctx context.Context) ([]models.SystemEvent, error)` - 收集 v$system_event 等待事件
- `CollectSessionMetrics(ctx context.Context) ([]models.SessionMetric, error)` - 收集会话级别统计指标
- `CollectSessionDetails(ctx context.Context) ([]models.SessionDetail, error)` - 收集会话详细信息
- `formatExecTime(seconds float64) string` - 格式化执行时间（MS/S/KS/WS）

**查询的视图**:
- `GV$SYSSTAT` - 系统统计（14 个指标）
- `GV$SYSTEM_EVENT` - 系统等待事件
- `GV$SESSION + GV$PROCESS + GV$SESSTAT + GV$STATNAME` - 会话统计
- `GV$SESSION + GV$PROCESS + V$SQLCOMMAND` - 会话详情

---

## 3. calculator 模块 - 指标计算层

### calculator/calculator.go
计算 delta、per-second 指标和 TOP N 排名。

**函数列表**:
- `NewCalculator(cfg *config.Config) *Calculator` - 创建计算器
- `CalculateSysStatDeltas(metrics []models.SysStatMetric, timestamp time.Time) []models.SysStatMetric` - 计算系统统计 delta 和每秒变化率
- `CalculateSystemEventDeltas(events []models.SystemEvent) []models.SystemEvent` - 计算等待事件 delta 并排序 TOP N
- `RankSessionMetrics(metrics []models.SessionMetric, timestamp time.Time) []models.SessionMetric` - 计算会话指标 delta 并按指定列排序 TOP N

**计算逻辑**:
- 存储上一次快照数据用于 delta 计算
- `delta_per_sec = (current_value - previous_value) / time_interval`
- 自动过滤零值和负值 delta
- 支持多实例环境

---

## 4. display 模块 - 显示层

### display/display.go
格式化输出监控数据到终端和文件。

**函数列表**:
- `NewDisplay(cfg *config.Config) (*Display, error)` - 创建显示器（可选打开输出文件）
- `Render(snapshot *models.Snapshot)` - 渲染完整监控界面
- `renderHeader(out *strings.Builder, timestamp time.Time)` - 渲染头部（时间戳、迭代次数）
- `renderSysStats(out *strings.Builder, metrics []models.SysStatMetric)` - 渲染 v$sysstat 指标（单行格式，支持多实例）
- `renderSystemEvents(out *strings.Builder, events []models.SystemEvent)` - 渲染 TOP N 等待事件
- `renderSessionMetrics(out *strings.Builder, metrics []models.SessionMetric)` - 渲染会话指标 TOP N
- `renderSessionDetails(out *strings.Builder, details []models.SessionDetail)` - 渲染活动会话详情
- `renderFooter(out *strings.Builder)` - 渲染页脚
- `colorize(text, color string) string` - 添加 ANSI 颜色代码
- `center(text string, width int) string` - 居中文本
- `truncate(text string, length int) string` - 截断文本
- `formatNumber(value float64) string` - 格式化数字（K/M/G 后缀）
- `Close() error` - 关闭输出文件

**显示特性**:
- 支持多实例显示（按 INST_ID 分组）
- 自动清屏和刷新
- 可选颜色输出
- 可选输出到文件（追加模式）

### display/interactive.go
交互式显示，支持键盘导航和操作。

**函数列表**:
- `NewInteractiveDisplay(d *Display, conn connector.Connector) *InteractiveDisplay` - 创建交互式显示器
- `RenderInteractive(snapshot *models.Snapshot)` - 渲染交互式界面（带选择高亮）
- `renderSessionDetailsInteractive(out *strings.Builder, details []models.SessionDetail)` - 渲染会话详情（带选择标记）
- `renderInteractiveFooter(out *strings.Builder)` - 渲染交互式页脚（键盘提示）
- `ShowHelp() string` - 显示帮助信息
- `MoveUp()` - 向上移动选择
- `MoveDown()` - 向下移动选择
- `GetSelectedSQLID() string` - 获取选中会话的 SQL ID
- `ExecuteSQLPlan(ctx context.Context) error` - 执行 SQL 计划查询
- `executeSQLScript(ctx context.Context, script string) (string, error)` - 执行 SQL 脚本

**交互式按键**:
- `↑/↓` - 上下移动选择
- `p` - 查看 SQL 执行计划
- `a` - 执行临时 SQL
- `s` - 执行脚本或命令
- `h` - 显示帮助
- `q` - 退出

---

## 5. executor 模块 - 脚本执行层

### executor/executor.go
执行 SQL 脚本和 OS 命令。

**函数列表**:
- `NewExecutor(cfg *config.Config, conn connector.Connector) *Executor` - 创建执行器
- `ExecuteCommand(ctx context.Context, input string) (string, error)` - 执行命令或脚本（自动识别 .sql）
- `executeSQLScript(ctx context.Context, scriptName string) (string, error)` - 执行 SQL 脚本（支持变量替换）
- `executeSQLViaSSHUpload(ctx context.Context, scriptContent, scriptName string) (string, error)` - 通过 SSH 上传并执行 SQL 脚本
- `executeSQLDirect(ctx context.Context, scriptContent string) (string, error)` - 直接执行 SQL 脚本
- `executeOSCommand(ctx context.Context, input string) (string, error)` - 执行 OS 命令或脚本
- `executeOSCommandViaSSH(ctx context.Context, command string) (string, error)` - 通过 SSH 执行 OS 命令
- `executeOSCommandLocal(ctx context.Context, command string) (string, error)` - 本地执行 OS 命令
- `executeOSScript(ctx context.Context, scriptContent string) (string, error)` - 执行 OS 脚本
- `ExecuteAdHocSQL(ctx context.Context, sql string) (string, error)` - 执行临时 SQL 语句
- `executeAdHocSQLViaSSH(ctx context.Context, sql string) (string, error)` - 通过 SSH 执行临时 SQL
- `executeAdHocSQLLocal(ctx context.Context, sql string) (string, error)` - 本地执行临时 SQL
- `findVariables(script string) []string` - 查找脚本中的 &var 和 &&var 变量
- `replaceVariable(script, variable, value string) string` - 替换变量（使用词边界精确匹配）
- `splitSQLStatements(script string) []string` - 分割 SQL 语句
- `isSQLPlusCommand(stmt string) bool` - 检测 SQL*Plus 命令
- `isLocalAuth() bool` - 检测是否使用本地认证（/ as sysdba）

**变量替换**:
- 支持 `&var` 和 `&&var` 变量
- 使用词边界正则避免冲突（如 &1 vs &11）
- 交互式提示输入变量值

**SSH 模式处理**:
- `/ as sysdba` 认证：上传脚本到远程执行
- `sys/password@host` 认证：直接执行
- 自动清理临时文件（debug 模式除外）

---

## 6. subcommand 模块 - 子命令框架

### subcommand/common.go
sesstat/sesevent 通用框架。

**数据结构**:
```go
type Record struct {
    InstID int
    SID    int
    Name   string
    Value1 int64   // TotalWaits 或其他
    Value2 float64 // TimeWaited 或 Value
}

type QueryConfig struct {
    ViewName      string   // 视图名称
    ValueColumns  []string // 值列名
    FilterColumn  string   // 过滤列名
    ExcludeFilter string   // 额外 WHERE 条件
    NoAlias       bool     // 是否不添加别名 a
}
```

**函数列表**:
- `CollectRecords(ctx context.Context, conn connector.Connector, qc *QueryConfig, instIDs, sids, names string) ([]Record, error)` - 通用数据收集
- `CalculateDeltas(prev, curr []Record, interval int) []Record` - 通用 delta 计算
- `RunSubcommand(ctx context.Context, conn connector.Connector, qc *QueryConfig, interval, count, topN int, instIDs, sids, names string, displayFunc func(...))` - 通用子命令执行流程
- `DisplayResults(deltas []Record, topN int, instIDs, sids, names string, sample, totalSamples int, title string, showValue1 bool)` - 通用结果显示
- `displayGroupedBySessions(deltas []Record, topN int, showValue1 bool)` - 按会话分组显示
- `displayDetailedRecords(deltas []Record, topN int, showValue1 bool)` - 显示详细记录

**执行流程**:
1. 收集 baseline 数据
2. 等待 interval 秒
3. 收集当前数据
4. 计算 delta
5. 显示结果
6. 重复步骤 2-5（count 次）

---

## 7. terminal 模块 - 终端交互辅助

### terminal/terminal.go
终端模式切换和输入处理。

**函数列表**:
- `WithTerminalRestore(oldState *term.State, fn func() error) error` - 自动恢复终端模式（执行函数前后切换 raw/normal 模式）
- `PromptInput(prompt string, maxLen int) string` - 通用输入提示（支持 ESC 取消、Backspace 删除）
- `WaitForKey(message string)` - 等待按键

**使用示例**:
```go
terminal.WithTerminalRestore(oldState, func() error {
    input := terminal.PromptInput("Enter SQL: ", 1024)
    // ... 处理输入
    terminal.WaitForKey("Press any key...")
    return nil
})
```

---

## 8. utils 模块 - 工具函数

### utils/utils.go
通用工具函数。

**函数列表**:
- `ParseCommaSeparatedInts(input string) ([]int, error)` - 解析并验证整数列表（防 SQL 注入）
- `ParseCommaSeparatedStrings(input string) []string` - 解析字符串列表
- `BuildInClause(columnName string, values []int) string` - 构建 IN 子句
- `BuildLikeClause(columnName string, patterns []string) string` - 构建 LIKE 子句
- `ShellEscape(s string) string` - Shell 转义（处理特殊字符）
- `ValidateSQLIdentifier(s string) bool` - SQL 标识符验证
- `Contains(slice []string, item string) bool` - 字符串切片包含检查

**安全特性**:
- 所有用户输入都经过验证
- SQL 注入防护
- Shell 注入防护

---

## 9. scripts 模块 - 嵌入式脚本管理

### scripts/scripts.go
管理嵌入编译的脚本。

**函数列表**:
- `GetSQLScript(name string) (string, error)` - 获取 SQL 脚本内容（从 scripts/sql/）
- `GetOSScript(name string) (string, error)` - 获取 OS 脚本内容（从 scripts/os/）
- `ReplaceSQLID(script, sqlID string) string` - 替换 &&sqlid 占位符
- `WriteSQLOutput(sqlID, output string) error` - 保存 SQL 输出到文件（sql_<sqlid>.txt）
- `WriteCommandOutput(command, output string) error` - 保存命令输出到文件（output_<command>.txt）

**嵌入目录**:
- `scripts/sql/*.sql` - SQL 脚本
- `scripts/os/*` - OS 命令脚本

---

## 10. config 模块 - 配置管理

### config/config.go
配置文件和参数管理。

**数据结构**:
```go
type Config struct {
    // Connection settings
    ConnectionMode string // "local" 或 "ssh"
    YasqlPath      string
    ConnectString  string

    // SSH settings
    SSHHost     string
    SSHPort     int
    SSHUser     string
    SSHPassword string
    SSHKeyFile  string
    SourceCmd   string

    // Display settings
    Interval           int
    Count              int
    OutputFile         string
    SessionTopN        int
    SessionSortBy      string
    SessionDetailTopN  int
    ShowTimestamp      bool
    ColorEnabled       bool
    InstanceID         int

    // Metric settings
    SysStatMetrics []string
    EventTopN      int

    // Advanced settings
    QueryTimeout   int
    SSHTimeout     int
    ReuseSSH       bool
    DebugMode      bool
}
```

**函数列表**:
- `DefaultConfig() *Config` - 返回默认配置
- `LoadConfig() (*Config, error)` - 从文件和命令行加载配置
- `loadFromFile(cfg *Config, path string) error` - 从 INI 文件加载配置
- `Validate() error` - 验证配置有效性
- `PrintUsage()` - 打印主程序使用说明
- `PrintSesstatUsage()` - 打印 sesstat 子命令使用说明
- `PrintSeseventUsage()` - 打印 sesevent 子命令使用说明

### config/global.go
全局参数解析。

**数据结构**:
```go
type GlobalFlags struct {
    ConfigFile     string
    ConnectionMode string
    YasqlPath      string
    ConnectString  string
    SSHHost        string
    SSHPort        int
    SSHUser        string
    SSHPassword    string
    SSHKeyFile     string
    SourceCmd      string
    Interval       int
    Count          int
    TopN           int
    OutputFile     string
    InstanceID     int
    Debug          bool
}
```

**函数列表**:
- `ParseGlobalFlags(fs *flag.FlagSet) *GlobalFlags` - 解析全局参数
- `ApplyToConfig(cfg *Config)` - 应用参数到配置

---

## 11. models 模块 - 数据模型

### models/models.go
定义所有数据结构。

**数据结构**:
```go
type SysStatMetric struct {
    InstID       int
    Name         string
    CurrentValue float64
    DeltaPerSec  float64
}

type SystemEvent struct {
    InstID      int
    EventName   string
    TotalWaits  int64
    TimeWaited  float64
    AvgWaitTime float64
    Percentage  float64
}

type SessionMetric struct {
    InstID   int
    SID      int
    Serial   int
    ThreadID int
    SidTid   string
    Username string
    SqlID    string
    Program  string
    Metrics  map[string]float64
}

type SessionDetail struct {
    InstID   int
    SidTid   string
    Event    string
    Username string
    SqlID    string
    ExecTime string
    Program  string
    Client   string
}

type Snapshot struct {
    Timestamp      time.Time
    SysStats       []SysStatMetric
    SystemEvents   []SystemEvent
    SessionMetrics []SessionMetric
    SessionDetails []SessionDetail
}
```

---

## 12. cmd/yastop 模块 - 主程序

### cmd/yastop/main.go
主入口，实现交互式监控模式。

**主要函数**:
- `main()` - 程序入口，路由到不同模式
- `runMonitor()` - 交互式监控主循环
- `readKeyboard()` - 键盘输入处理（支持方向键、p/a/s/h/q）
- `collectSnapshot()` - 收集一次完整的性能快照

**交互式按键**:
- `↑/↓` - 上下移动选择会话
- `p` - 查看选中会话的 SQL 执行计划
- `a` - 执行临时 SQL 语句
- `s` - 执行 SQL 脚本或 OS 命令
- `h` - 显示帮助信息
- `q` - 退出

### cmd/yastop/sesstat.go
会话统计子命令。

**主要函数**:
- `runSesstat()` - 子命令入口

**特点**:
- 使用 subcommand 框架
- 支持按 SID、统计名称过滤
- 显示 TOP N 会话或统计项

### cmd/yastop/sesevent.go
会话等待事件子命令。

**主要函数**:
- `runSesevent()` - 子命令入口

**特点**:
- 使用 subcommand 框架
- 自动过滤 Idle 事件
- 显示等待时间、次数、平均等待

---

## 使用示例

### 1. 收集系统统计
```go
collector := collector.NewCollector(cfg, conn)
metrics, err := collector.CollectSysStats(ctx)
```

### 2. 计算 delta
```go
calculator := calculator.NewCalculator(cfg)
deltas := calculator.CalculateSysStatDeltas(metrics, time.Now())
```

### 3. 显示结果
```go
display, _ := display.NewDisplay(cfg)
display.Render(snapshot)
```

### 4. 执行 SQL 脚本
```go
executor := executor.NewExecutor(cfg, conn)
output, err := executor.ExecuteCommand(ctx, "sql.sql")
```

### 5. 解析用户输入
```go
ids, err := utils.ParseCommaSeparatedInts("1,2,3")
clause := utils.BuildInClause("inst_id", ids)
```

### 6. 终端交互
```go
terminal.WithTerminalRestore(oldState, func() error {
    input := terminal.PromptInput("Enter value: ", 256)
    fmt.Println("You entered:", input)
    terminal.WaitForKey("Press any key...")
    return nil
})
```

---

## 扩展指南

### 添加新的数据收集
1. 在 `collector/collector.go` 添加新方法
2. 定义 SQL 查询
3. 解析结果到模型
4. 在 `calculator/` 添加计算逻辑
5. 在 `display/` 添加显示逻辑

### 添加新的子命令
1. 在 `cmd/yastop/` 创建新文件
2. 定义 `runNewSub()` 函数
3. 创建 `QueryConfig` 配置
4. 调用 `subcommand.RunSubcommand()`
5. 在 `main.go` 添加路由

### 添加新的嵌入脚本
1. 将脚本放到 `scripts/sql/` 或 `scripts/os/`
2. 脚本自动嵌入编译
3. 使用 `scripts.GetSQLScript()` 或 `scripts.GetOSScript()` 获取

---

## 总结

yastop 提供了完整的模块化框架，所有功能都通过清晰的接口和函数暴露。开发新功能时：

1. **数据收集** → 使用 `collector` 模块
2. **数据计算** → 使用 `calculator` 模块
3. **数据显示** → 使用 `display` 模块
4. **脚本执行** → 使用 `executor` 模块
5. **子命令** → 使用 `subcommand` 框架
6. **终端交互** → 使用 `terminal` 辅助函数
7. **工具函数** → 使用 `utils` 模块

所有模块都遵循单一职责原则，便于测试和维护。
