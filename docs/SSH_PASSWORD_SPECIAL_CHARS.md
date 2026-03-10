# SSH 密码含特殊字符无法连接 — 复现、原因与方案

## 1. 问题描述

使用 `-p` 传入带特殊字符的 SSH 密码时，无法连上服务器，例如：

```bash
yastop -h 10.10.10.130 -u yashan -p 'Oracle1!' -i 2 -c 3
```

密码 `Oracle1!` 中的 `!` 等字符在经 shell 传参时可能被改写，导致程序拿到的并非用户输入的密码。

---

## 2. 复现方式

### 2.1 自动化测试（不依赖真实服务器）

在仓库根目录执行：

```bash
cd internal/config && go test -v -run "Reproduce|Solution"
```

- **TestReproduce_SSHPasswordViaShell_DoubleQuotes**：在 `bash -H` 下用双引号传 `-p "Oracle1!"`，若子进程收到的字符串与预期不一致则复现成功。注意：在非交互的 `bash -c` 子进程中有时不会触发 history 展开，该测试可能通过，但**交互式终端**或**脚本中**用双引号传含 `!` 的密码仍可能被篡改。
- **TestReproduce_SSHPasswordViaShell_SingleQuotes**：用单引号传 `-p 'Oracle1!'`，验证单引号下通常不会被篡改。
- **TestSolution_***：验证从环境变量或文件读取的密码能完整保留 `Oracle1!`，用于确认后续方案可行。

### 2.2 在真实环境复现（可选）

1. 在 10.10.10.130 上用 root（免密）登录，将 yashan 密码设为 `Oracle1!`。
2. 在本地分别执行：
   - `yastop -h 10.10.10.130 -u yashan -p "Oracle1!" -i 1 -c 1`（双引号）
   - `yastop -h 10.10.10.130 -u yashan -p 'Oracle1!' -i 1 -c 1`（单引号）
3. 若双引号方式连接失败而单引号成功，或两种方式都失败（与 shell 配置有关），则说明「密码经命令行传参」在含特殊字符时不可靠。

---

## 3. 原因分析

### 3.1 Shell 对参数的处理

- **双引号 `"Oracle1!"`**：在 bash 中，双引号内会进行变量替换、命令替换和 **history expansion**。`!` 会触发历史展开（如 `!$`、`!n` 等），所以 `"Oracle1!"` 在启用 `set -H` 或默认启用了 history 的交互式 bash 下，可能被改成其它字符串，程序收到的就不是 `Oracle1!`。
- **单引号 `'Oracle1!'`**：单引号内除单引号本身外都不做解释，`!` 会原样传给程序。因此**单引号通常能正确传递**，但依赖用户记得用单引号，且不同 shell（dash、zsh 等）行为不完全一致。
- **不加引号 `-p Oracle1!`**：`!` 同样可能被 history 展开，且会受 IFS、通配符等影响，极易出错。

### 3.2 程序侧

- yastop 通过 `flag.String("p", "", "SSH password")` 读取密码，得到的是**操作系统传入的 argv**。
- 若 shell 在调用 exec 前已把 `"Oracle1!"` 展开成别的字符串，程序无法区分「用户输入」和「被改写后的值」，因此问题根源在**调用链上的 shell**，而不是 Go 的 flag 解析或 SSH 库。

### 3.3 结论

- **根本原因**：密码通过**命令行参数** `-p` 传递时，会先经过 shell 解析（尤其是双引号 + `!` 时的 history expansion），导致含 `!` 等字符的密码被篡改。
- **复现条件**：使用双引号或未加引号，且在启用 history expansion 的 shell 下执行。

---

## 4. 解决方案（思路，不写具体实现）

目标：**避免把「含特殊字符的密码」放在命令行参数里**，改为从「不经过 shell 解析」的渠道读取。

### 4.1 方案 A：环境变量（推荐之一）

- 新增支持从环境变量读取 SSH 密码，例如 `YASTOP_SSH_PASSWORD`。
- 若已设置该变量，且未通过 `-p` / `--ssh-password` 传参，则使用环境变量作为密码。
- 用户用法示例：`export YASTOP_SSH_PASSWORD='Oracle1!'` 或 `YASTOP_SSH_PASSWORD='Oracle1!' yastop -h ... -u yashan ...`（不写 `-p`）。
- **优点**：不经过子 shell 对 `-p` 的解析，避免 `!` 等被改写；脚本里也易写。
- **验证**：已通过 `TestSolution_PasswordFromEnv` 验证「从 env 读取的字符串能完整保留 Oracle1!」。

### 4.2 方案 B：密码文件（推荐之一）

- 新增选项 `--ssh-password-file`，值为文件路径；程序从该文件**第一行**读取密码（trim 首尾空白）。
- 若未提供 `-p` 且提供了 `--ssh-password-file`，则用文件内容作为密码。
- 用户用法示例：`echo -n 'Oracle1!' > ~/.yastop_pass && chmod 600 ~/.yastop_pass`，再执行 `yastop -h ... -u yashan --ssh-password-file ~/.yastop_pass ...`。
- **优点**：密码完全不出现在命令行与进程列表中；适合脚本和自动化。
- **验证**：已通过 `TestSolution_PasswordFromFile` 与 `TestSolution_PasswordFromFile_FirstLineOnly` 验证「从文件首行读取能完整保留 Oracle1!」。

### 4.3 方案 C：交互式提示输入（可选）

- 当连接方式为 SSH 且既未提供 `-p`/密码文件/环境变量，也未提供密钥文件时，在终端提示用户输入密码（关闭回显）。
- **优点**：密码不落命令行、不落文件；**缺点**：不适合非交互式/脚本场景。

### 4.4 优先级建议

1. 实现 **环境变量** 与 **密码文件**，二者互补（脚本用 env 或 file，交互用 file 或后续的交互输入）。
2. 文档中明确说明：**含 `!`、`$`、引号等字符的密码，不要用 `-p "..."`，请用单引号、环境变量或密码文件**。
3. 可选：在帮助信息中提示「密码含特殊字符时请使用 YASTOP_SSH_PASSWORD 或 --ssh-password-file」。

---

## 5. 方案可行性验证（仅测试，不改主逻辑）

当前已用测试验证「不通过命令行传参」时，密码能完整保留：

| 测试 | 验证内容 |
|------|----------|
| `TestSolution_PasswordFromEnv` | 从环境变量读取的字符串与 `Oracle1!` 一致 |
| `TestSolution_PasswordFromFile` | 从文件读取的第一行（trim 后）与 `Oracle1!` 一致 |
| `TestSolution_PasswordFromFile_FirstLineOnly` | 只取第一行、忽略后续行，且 trim 后与 `Oracle1!` 一致 |

结论：**在实现「从环境变量或文件读取密码」后，再在配置/连接逻辑中优先使用这两者（在未提供 `-p` 时），即可避免特殊字符被 shell 篡改，且上述测试已证明该思路可行。** 下一步只需在 config 加载与 SSH 连接处接入 env/file 读取逻辑即可（不在此文档中写具体代码）。
