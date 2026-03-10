# yastop 架构与功能总结

## 项目概述

yastop 是一个 YashanDB 实时性能监控工具，类似于 Oracle 的 oratop。支持本地和 SSH 远程连接，提供交互式监控界面和子命令查询功能。

## 目录结构

```
yastop/
├── cmd/yastop/              # 主程序入口
│   ├── main.go             # 主函数和 monitor 交互模式
│   ├── sesstat.go          # 会话统计子命令
│   └── sesevent.go         # 会话事件子命令
├── internal/
│   ├── calculator/         # 指标计算（delta、per-second）
│   ├── collector/          # 数据收集（查询 v$ 视图）
│   ├── config/             # 配置管理
│   ├── connector/          # 数据库连接抽象层
│   ├── display/            # TUI 显示
│   ├── executor/           # 脚本和命令执行
│   ├── models/             # 数据模型
│   ├── scripts/            # 嵌入式脚本管理
│   ├── subcommand/         # 子命令通用框架
│   ├── terminal/           # 终端交互辅助
│   └── utils/              # 通用工具函数
└── scripts/
    ├── sql/                # SQL 脚本（嵌入编译）
    └── os/                 # OS 命令脚本（嵌入编译）
```

## 核心模块详解

### 1. cmd/yastop - 主程序

#### main.go
**功能**: 主入口，实现交互式监控模式

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

**命令行参数**:
```bash
yastop [monitor]              # 交互式监控（默认）
yastop sesstat|stat [options] # 会话统计子命令
yastop sesevent|event [options] # 会话事件子命令
```

#### sesstat.go
**功能**: 查询会话统计信息（v$sesstat + v$statname）

**主要函数**:
- `runSesstat()` - 子命令入口

**特点**:
- 使用 subcommand 框架
- 支持按 SID、统计名称过滤
- 显示 TOP N 会话或统计项

#### sesevent.go
**功能**: 查询会话等待事件（gv$session_event）

**主要函数**:
- `runSesevent()` - 子命令入口

**特点**:
- 使用 subcommand 框架
- 自动过滤 Idle 事件
- 显示等待时间、次数、平均等待

---

### 2. internal/connector - 数据库连接层

#### interface.go
**接口定义**:
```go
type Connector interface {
    Connect(ctx context.Context) error
    ExecuteQuery(ctx context.Context, sql string) ([][]string, error)
    Close() error
    IsConnected() bool
}
```

#### local.go
**功能**: 本地 yasql 连接

**实现方式**:
- 使用 `os/exec` 执行 yasql 命令
- 支持 `/ as sysdba` 或 `sys/password` 认证

#### ssh.go
**功能**: SSH 远程 yasql 连接

**实现方式**:
- 使用 `golang.org/x/crypto/ssh` 建立 SSH 连接
- 支持密码和私钥认证
- 可选执行 source 命令（如 `source ~/.bashrc`）

**主要函数**:
- `Connect()` - 建立 SSH 连接
- `ExecuteQuery()` - 通过 SSH 执行 yasql 查询
- `ExecuteCommand()` - 执行原始 shell 命令

#### parser.go
**功能**: 解析 yasql 输出

**主要函数**:
- `parseYasqlOutput(output string) ([][]string, error)` - 解析固定宽度列输出
- `parseFixedWidthLine()` - 解析单行数据
- `checkYashanError()` - 检测 YAS-NNNNN 错误码

**错误检测**:
- 自动识别 `YAS-\d{5}` 格式的错误
- 提取错误信息并返回详细错误

---

### 3. internal/collector - 数据收集层

#### collector.go
**功能**: 封装所有数据收集逻辑

**主要函数**:
- `CollectSysStats()` - 收集 v$sysstat 指标
- `CollectSystemEvents()` - 收集 v$system_event
- `CollectSessionMetrics()` - 收集会话级别指标
- `CollectSessionDetails()` - 收集会话详细信息

**查询的视图**:
- `v$sysstat` - 系统统计
- `v$system_event` - 系统等待事件
- `gv$sesstat` + `v$statname` - 会话统计
- `gv$session` + `gv$process` - 会话详情

---

### 4. internal/calculator - 指标计算层

#### calculator.go
**功能**: 计算 delta 和 per-second 指标

**主要函数**:
- `CalculateSysStats()` - 计算系统统计 delta
- `CalculateSystemEvents()` - 计算等待事件 delta
- `CalculateSessionMetrics()` - 计算会话指标 delta

**计算逻辑**:
```go
delta_per_sec = (current_value - previous_value) / time_interval
```

---

### 5. internal/display - 显示层

#### display.go
**功能**: 格式化输出监控数据

**主要函数**:
- `Render()` - 渲染完整监控界面
- `renderSysStats()` - 渲染系统统计
- `renderSystemEvents()` - 渲染等待事件
- `renderSessionMetrics()` - 渲染会话指标
- `renderSessionDetails()` - 渲染会话详情

#### interactive.go
**功能**: 交互式显示（支持选择和操作）

**主要函数**:
- `RenderInteractive()` - 渲染交互式界面
- `MoveUp()` / `MoveDown()` - 移动选择
- `GetSelectedSQLID()` - 获取选中会话的 SQL ID
- `ExecuteSQLPlan()` - 执行 SQL 计划查询
- `ShowHelp()` - 显示帮助信息

---

### 6. internal/executor - 脚本执行层

#### executor.go
**功能**: 执行 SQL 脚本和 OS 命令

**主要函数**:
- `ExecuteCommand()` - 执行命令或脚本（自动识别 .sql）
- `ExecuteAdHocSQL()` - 执行临时 SQL 语句
- `executeSQLScript()` - 执行 SQL 脚本（支持变量替换）
- `executeOSCommand()` - 执行 OS 命令

**变量替换**:
- 支持 `&var` 和 `&&var` 变量
- 使用词边界正则避免冲突（如 &1 vs &11）
- 交互式提示输入变量值

**SSH 模式处理**:
- `/ as sysdba` 认证：上传脚本到远程执行
- `sys/password@host` 认证：直接执行
- 自动清理临时文件（debug 模式除外）

---

### 7. internal/subcommand - 子命令框架

#### common.go
**功能**: sesstat/sesevent 通用框架

**核心结构**:
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

**主要函数**:
- `CollectRecords()` - 通用数据收集
- `CalculateDeltas()` - 通用 delta 计算
- `DisplayResults()` - 通用结果显示
- `RunSubcommand()` - 通用子命令执行流程

**执行流程**:
1. 收集 baseline 数据
2. 等待 interval 秒
3. 收集当前数据
4. 计算 delta
5. 显示结果
6. 重复步骤 2-5（count 次）

---

### 8. internal/terminal - 终端交互辅助

#### terminal.go
**功能**: 终端模式切换和输入处理

**主要函数**:
- `WithTerminalRestore()` - 自动恢复终端模式
- `PromptInput()` - 通用输入提示（支持 ESC 取消）
- `WaitForKey()` - 等待按键

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

### 9. internal/utils - 工具函数

#### utils.go
**功能**: 通用工具函数

**主要函数**:
- `ParseCommaSeparatedInts()` - 解析并验证整数列表（防 SQL 注入）
- `ParseCommaSeparatedStrings()` - 解析字符串列表
- `BuildInClause()` - 构建 IN 子句
- `BuildLikeClause()` - 构建 LIKE 子句
- `ShellEscape()` - Shell 转义（处理特殊字符）
- `ValidateSQLIdentifier()` - SQL 标识符验证
- `Contains()` - 字符串切片包含检查

**安全特性**:
- 所有用户输入都经过验证
- SQL 注入防护
- Shell 注入防护

---

### 10. internal/config - 配置管理

#### config.go
**功能**: 配置文件和参数管理

**配置结构**:
```go
type Config struct {
    ConnectionMode string // "local" 或 "ssh"
    YasqlPath      string // yasql 可执行文件路径
    ConnectString  string // 连接字符串

    // SSH 配置
    SSHHost     string
    SSHUser     string
    SSHPassword string
    SSHKeyFile  string
    SSHTimeout  int
    SourceCmd   string // source 命令

    // 监控配置
    Interval   int    // 刷新间隔（秒）
    Count      int    // 输出次数
    TopN       int    // TOP N 数量
    InstanceID int    // 实例 ID（0=全部）
    OutputFile string // 输出文件
    DebugMode  bool   // 调试模式
}
```

#### global.go
**功能**: 全局参数解析

**主要函数**:
- `ParseGlobalFlags()` - 解析全局参数
- `ApplyToConfig()` - 应用参数到配置

**参数列表**:
```
-h, --host      SSH 主机
-u, --user      SSH 用户
-p, --password  SSH 密码
-k, --key       SSH 私钥文件
-s, --source    Source 命令
-C, --connect   连接字符串
-i, --interval  刷新间隔
-c, --count     输出次数
-t, --top       TOP N 数量
-I, --inst      实例 ID
-o, --output    输出文件
-d, --debug     调试模式
```

---

### 11. internal/scripts - 嵌入式脚本管理

#### scripts.go
**功能**: 管理嵌入编译的脚本

**嵌入目录**:
- `scripts/sql/*.sql` - SQL 脚本
- `scripts/os/*` - OS 命令脚本

**主要函数**:
- `GetSQLScript()` - 获取 SQL 脚本内容
- `GetOSScript()` - 获取 OS 脚本内容
- `WriteSQLOutput()` - 保存 SQL 输出到文件
- `WriteCommandOutput()` - 保存命令输出到文件

---

## 数据流程

### 监控模式（monitor）
```
用户启动 → runMonitor()
    ↓
创建 Connector → 连接数据库
    ↓
主循环:
    collectSnapshot()
        ↓
    Collector.CollectXXX() → 查询数据库
        ↓
    Calculator.CalculateXXX() → 计算 delta
        ↓
    Display.Render() → 显示结果
        ↓
    等待 interval 或键盘输入
```

### 子命令模式（sesstat/sesevent）
```
用户执行子命令 → runSesstat()/runSesevent()
    ↓
创建 QueryConfig → 配置查询参数
    ↓
subcommand.RunSubcommand()
    ↓
循环 count+1 次:
    1. CollectRecords() → 查询数据
    2. CalculateDeltas() → 计算 delta
    3. DisplayResults() → 显示结果
    4. 等待 interval
```

### 脚本执行流程
```
用户按 's' → promptForCommand()
    ↓
Executor.ExecuteCommand()
    ↓
识别类型:
    .sql → executeSQLScript()
        ↓
    findVariables() → 查找变量
        ↓
    提示输入变量值
        ↓
    replaceVariable() → 替换变量
        ↓
    执行 SQL（本地或 SSH）

    其他 → executeOSCommand()
        ↓
    执行命令（本地或 SSH）
```

---

## 关键设计模式

### 1. 接口抽象
- `Connector` 接口统一本地和 SSH 连接
- 便于扩展其他连接方式

### 2. 策略模式
- `Executor` 根据连接模式选择执行策略
- SSH + sysdba：上传脚本
- SSH + password：直接执行

### 3. 模板方法
- `subcommand.RunSubcommand()` 定义通用流程
- 具体子命令提供配置和显示函数

### 4. 工厂模式
- `connector.NewConnector()` 根据配置创建连接器

---

## 安全特性

### 1. SQL 注入防护
- 所有用户输入通过 `utils.ParseCommaSeparatedInts()` 验证
- 使用 `utils.BuildInClause()` 安全构建 SQL

### 2. Shell 注入防护
- 使用 `utils.ShellEscape()` 转义特殊字符
- SSH 密码使用 `ssh.Password()` 安全传递

### 3. 资源管理
- 使用 `defer` 确保资源清理
- 临时文件自动删除（debug 模式除外）

### 4. 错误检测
- 自动检测 YashanDB 错误码（YAS-NNNNN）
- 详细错误信息输出

---

## 扩展指南

### 添加新的子命令

1. 在 `cmd/yastop/` 创建新文件（如 `newsub.go`）
2. 定义 `runNewSub()` 函数
3. 创建 `QueryConfig` 配置
4. 调用 `subcommand.RunSubcommand()`
5. 在 `main.go` 添加路由

示例:
```go
func runNewSub() {
    // 解析参数
    globalFlags := config.ParseGlobalFlags(fs)

    // 创建连接
    conn, _ := connector.NewConnector(cfg)
    conn.Connect(ctx)
    defer conn.Close()

    // 配置查询
    qc := &subcommand.QueryConfig{
        ViewName:      "gv$new_view",
        ValueColumns:  []string{"a.value1", "a.value2"},
        FilterColumn:  "a.name",
        ExcludeFilter: "a.status = 'ACTIVE'",
    }

    // 执行
    subcommand.RunSubcommand(ctx, conn, qc, ...)
}
```

### 添加新的数据收集

1. 在 `collector/collector.go` 添加新方法
2. 定义 SQL 查询
3. 解析结果到模型
4. 在 `calculator/` 添加计算逻辑
5. 在 `display/` 添加显示逻辑

### 添加新的嵌入脚本

1. 将脚本放到 `scripts/sql/` 或 `scripts/os/`
2. 脚本自动嵌入编译
3. 使用 `scripts.GetSQLScript()` 或 `scripts.GetOSScript()` 获取

---

## 常用代码片段

### 执行 SQL 查询
```go
rows, err := conn.ExecuteQuery(ctx, "SELECT * FROM v$sysstat")
if err != nil {
    return fmt.Errorf("query failed: %w", err)
}
```

### 解析用户输入
```go
ids, err := utils.ParseCommaSeparatedInts("1,2,3")
clause := utils.BuildInClause("inst_id", ids)
// 生成: inst_id IN (1,2,3)
```

### 终端交互
```go
terminal.WithTerminalRestore(oldState, func() error {
    input := terminal.PromptInput("Enter value: ", 256)
    fmt.Println("You entered:", input)
    terminal.WaitForKey("Press any key...")
    return nil
})
```

### 执行脚本
```go
exec := executor.NewExecutor(cfg, conn)
output, err := exec.ExecuteCommand(ctx, "sql.sql")
```

---

## 性能优化建议

1. **连接复用**: SSH 连接在整个会话中复用
2. **批量查询**: 尽量合并多个查询
3. **增量计算**: 只计算变化的指标
4. **缓存结果**: 避免重复查询静态数据

---

## 调试技巧

### 启用调试模式
```bash
yastop -d  # 显示 SQL 和输出
```

### 查看生成的 SQL
```bash
yastop sesstat -d -S 40,50
# 输出:
# [DEBUG] SQL: SELECT a.inst_id, a.sid, b.name, a.value ...
```

### 保留临时文件
```bash
yastop -d  # debug 模式不删除临时文件
```

---

## 版本信息

- **当前版本**: 重构后版本
- **代码行数**: ~3830 行（从 3970 减少 140 行）
- **重复代码消除**: 663 行
- **代码减少**: 17%

---

## 依赖项

```go
golang.org/x/term        // 终端控制
golang.org/x/crypto/ssh  // SSH 连接
```

---

## 文件清单

### 核心文件
- `cmd/yastop/main.go` (301 行) - 主程序
- `cmd/yastop/sesstat.go` (91 行) - 会话统计
- `cmd/yastop/sesevent.go` (91 行) - 会话事件

### 连接层
- `internal/connector/interface.go` - 接口定义
- `internal/connector/local.go` (76 行) - 本地连接
- `internal/connector/ssh.go` (200 行) - SSH 连接
- `internal/connector/parser.go` (98 行) - 输出解析

### 工具层
- `internal/utils/utils.go` - 通用工具
- `internal/terminal/terminal.go` (84 行) - 终端辅助
- `internal/subcommand/common.go` (375 行) - 子命令框架
- `internal/executor/executor.go` (350 行) - 脚本执行

### 业务层
- `internal/collector/` - 数据收集
- `internal/calculator/` - 指标计算
- `internal/display/` - 显示渲染
- `internal/config/` - 配置管理
- `internal/models/` - 数据模型
- `internal/scripts/` - 脚本管理

---

## 总结

yastop 是一个模块化、可扩展的数据库监控工具。通过清晰的分层架构和通用框架，可以轻松添加新功能。所有用户输入都经过验证，确保安全性。支持本地和远程连接，提供交互式和命令行两种使用方式。
