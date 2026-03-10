# OS Command Execution Test

## Overview
The 's' key in monitoring mode already supports executing OS commands directly.

## How It Works

### Code Flow
1. User presses 's' in monitoring mode
2. Prompt: "Enter SQL script (.sql) or OS command (ESC to cancel): "
3. User input is processed by `ExecuteCommand()`:
   - If input ends with `.sql` → execute as SQL script
   - Otherwise → execute as OS command

### Implementation Details

From `internal/executor/executor.go`:

```go
func (e *Executor) ExecuteCommand(ctx context.Context, input string) (string, error) {
    input = strings.TrimSpace(input)
    if input == "" {
        return "", fmt.Errorf("empty command")
    }

    // Check if it's a SQL script
    if strings.HasSuffix(input, ".sql") {
        return e.executeSQLScript(ctx, input)
    }

    // Check if it's an OS command/script
    return e.executeOSCommand(ctx, input)
}
```

### OS Command Execution

```go
func (e *Executor) executeOSCommand(ctx context.Context, input string) (string, error) {
    // Check if it's an embedded OS script (no spaces = might be script name)
    if !strings.Contains(input, " ") {
        scriptContent, err := scripts.GetOSScript(input)
        if err == nil {
            return e.executeOSScript(ctx, scriptContent)
        }
    }

    // Execute as shell command
    if e.cfg.ConnectionMode == "ssh" {
        return e.executeOSCommandViaSSH(ctx, input)
    }

    return e.executeOSCommandLocal(ctx, input)
}
```

## Usage Examples

### Example 1: iostat Command
```
Press 's' in monitoring mode
Enter SQL script (.sql) or OS command: iostat 3 4

Output:
[iostat output showing 4 samples at 3-second intervals]

Output saved to: output_iostat_3_4.txt
Press any key to continue...
```

### Example 2: vmstat Command
```
Press 's' in monitoring mode
Enter SQL script (.sql) or OS command: vmstat 1 5

Output:
[vmstat output showing 5 samples at 1-second intervals]

Output saved to: output_vmstat_1_5.txt
Press any key to continue...
```

### Example 3: ps Command
```
Press 's' in monitoring mode
Enter SQL script (.sql) or OS command: ps aux | grep yashandb

Output:
[process list filtered by yashandb]

Output saved to: output_ps_aux___grep_yashandb.txt
Press any key to continue...
```

### Example 4: df Command
```
Press 's' in monitoring mode
Enter SQL script (.sql) or OS command: df -h

Output:
[disk usage information]

Output saved to: output_df_-h.txt
Press any key to continue...
```

### Example 5: Custom Shell Script
```
Press 's' in monitoring mode
Enter SQL script (.sql) or OS command: ./monitor_system.sh

Output:
[script output]

Output saved to: output_.monitor_system.sh.txt
Press any key to continue...
```

## Connection Modes

### Local Mode
Commands are executed locally using:
```go
cmd := exec.CommandContext(ctx, "bash", "-c", command)
output, err := cmd.CombinedOutput()
```

### SSH Mode
Commands are executed on remote host via SSH:
```go
// If source_cmd is configured, it's prepended
if e.cfg.SourceCmd != "" {
    command = e.cfg.SourceCmd + " && " + command
}
return sshConn.ExecuteCommand(ctx, command)
```

## Output Handling

All command outputs are:
1. **Displayed on screen** after execution
2. **Saved to file** using `scripts.WriteCommandOutput()`
   - Filename format: `output_<sanitized_command>.txt`
   - Special characters replaced with underscores
   - Truncated to 50 characters if too long

Example filename transformations:
- `iostat 3 4` → `output_iostat_3_4.txt`
- `ps aux | grep yashandb` → `output_ps_aux___grep_yashandb.txt`
- `df -h` → `output_df_-h.txt`

## Embedded OS Scripts

If input has no spaces, the system first checks for embedded scripts in `scripts/os/`:

```
Press 's' in monitoring mode
Enter SQL script (.sql) or OS command: monitor

→ First tries to load from embedded scripts/os/monitor
→ If not found, executes as shell command "monitor"
```

## Error Handling

If command execution fails:
```
Error executing command: command failed: exit status 1
[error output from command]

Press any key to continue...
```

The error is displayed but doesn't crash the monitoring session.

## Security Notes

- Commands are executed with the same privileges as the yastop process
- In SSH mode, commands run with the SSH user's privileges
- Be cautious with commands that:
  - Modify system state
  - Require elevated privileges
  - Have long execution times (may block monitoring)

## Testing Commands

Safe commands to test:
```bash
# System information
uname -a
hostname
uptime
date

# Resource monitoring
iostat 1 3
vmstat 1 3
free -h
df -h

# Process information
ps aux | head -20
top -b -n 1 | head -20

# Network information
netstat -an | head -20
ss -tuln
```

## Limitations

1. **Interactive commands** (like `top`, `vi`) won't work properly
2. **Long-running commands** will block until completion
3. **Commands requiring input** will hang
4. **Background jobs** (`&`) may not behave as expected

For long-running monitoring, use commands with limited iterations:
- ✅ `iostat 1 5` (5 samples)
- ❌ `iostat 1` (runs forever)

## Summary

✅ **Already Implemented**: The 's' key fully supports OS command execution
✅ **Works in both modes**: Local and SSH
✅ **Output saved**: All outputs saved to files automatically
✅ **Error handling**: Graceful error display without crashing
✅ **Flexible input**: Supports pipes, redirects, and complex commands
