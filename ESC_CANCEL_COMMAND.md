# ESC Key to Cancel Running Commands

## Feature Overview

When executing long-running commands via the 's' key in monitoring mode, you can now press ESC to cancel the command and return to the monitoring interface immediately.

## Implementation

### How It Works

1. **Cancellable Context**: Command execution uses `context.WithCancel()`
2. **ESC Monitoring**: A goroutine monitors stdin for ESC key (byte 27)
3. **Graceful Cancellation**: When ESC is pressed:
   - Context is cancelled
   - Command receives cancellation signal
   - Cleanup happens automatically
   - User returns to monitoring interface

### Code Flow

```go
// Create cancellable context
cmdCtx, cmdCancel := context.WithCancel(ctx)

// Execute command in goroutine
go func() {
    output, err := exec.ExecuteCommand(cmdCtx, command)
    resultChan <- result
}()

// Monitor for ESC key
go func() {
    buf := make([]byte, 1)
    for {
        n, _ := os.Stdin.Read(buf)
        if buf[0] == 27 { // ESC key
            escChan <- true
            return
        }
    }
}()

// Wait for completion or ESC
select {
case result := <-resultChan:
    // Command completed normally
case <-escChan:
    cmdCancel() // Cancel the command
    fmt.Println("\n[Command cancelled by user]")
}
```

## Usage Examples

### Example 1: Cancel iostat
```bash
# In monitoring mode, press 's'
Enter command: iostat 3

# Output starts appearing...
Linux 5.10.0 (hostname)     03/06/2026

avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           2.50    0.00    1.25    0.25    0.00   96.00

# Press ESC to cancel
[Command cancelled by user]

Press any key to continue...
# Returns to monitoring interface
```

### Example 2: Cancel Long Script
```bash
# In monitoring mode, press 's'
Enter command: ./long_running_script.sh

# Script output appears...
Starting process...
Step 1 completed...
Step 2 in progress...

# Press ESC to cancel
[Command cancelled by user]

Press any key to continue...
# Returns to monitoring interface
```

### Example 3: Cancel SSH Command
```bash
# Connected via SSH
./yastop -h 10.10.10.130 -u username

# In monitoring mode, press 's'
Enter command: iostat 3

# Remote output appears...
# Press ESC to cancel
[Command cancelled by user]

Press any key to continue...
# Returns to monitoring interface
```

## Testing

### Test 1: Infinite Command
```bash
# Start yastop
./yastop

# Press 's' and enter:
ping google.com

# Let it run for a few pings, then press ESC
# Should see: [Command cancelled by user]
# Should return to monitoring interface
```

### Test 2: Long Sleep
```bash
# Press 's' and enter:
sleep 60

# Immediately press ESC
# Should cancel and return to monitoring
```

### Test 3: Script with Loop
```bash
# Press 's' and enter:
for i in {1..100}; do echo "Line $i"; sleep 1; done

# Press ESC after a few lines
# Should cancel and return to monitoring
```

## Behavior Details

### What Happens on ESC

1. **Context Cancellation**: `cmdCtx.Done()` channel is closed
2. **Command Termination**:
   - Local: Process receives SIGKILL
   - SSH: SSH session is closed
3. **Cleanup**: Goroutines exit gracefully
4. **User Feedback**: "[Command cancelled by user]" message
5. **Return**: Back to monitoring interface

### Partial Output

- Output displayed before ESC is **preserved**
- Output is **saved to file** even if cancelled
- File will contain partial output up to cancellation point

### Timing

- **Immediate Response**: ESC is detected within milliseconds
- **Cleanup Delay**: 500ms wait for process cleanup
- **No Hanging**: Even if process doesn't respond, yastop returns to monitoring

## Edge Cases

### 1. Command Completes Before ESC
```
User presses ESC, but command already finished
→ Normal completion, ESC is ignored
```

### 2. Multiple ESC Presses
```
User presses ESC multiple times
→ Only first ESC is processed, others ignored
```

### 3. ESC During Output
```
Command is printing output when ESC pressed
→ Output stops immediately, cleanup happens
```

### 4. Non-Cancellable Commands
```
Some commands may not respond to cancellation
→ yastop waits 500ms then returns anyway
```

## Limitations

### Commands That May Not Cancel Cleanly

1. **Shell Built-ins**: Some built-in commands may not respect context cancellation
2. **Zombie Processes**: Cancelled processes may become zombies (rare)
3. **SSH Latency**: SSH commands may take longer to cancel due to network latency

### Workarounds

For commands that don't cancel cleanly:
```bash
# Use timeout command
timeout 30 your_command

# Or use commands with built-in limits
iostat 1 10  # Instead of iostat 1 (infinite)
```

## Comparison with Ctrl+C

### ESC Key (Recommended)
- ✅ Returns to monitoring interface
- ✅ Preserves yastop state
- ✅ Clean cancellation
- ✅ Partial output saved

### Ctrl+C (Not Recommended)
- ❌ Exits entire yastop program
- ❌ Loses monitoring state
- ❌ No cleanup
- ❌ Output not saved

## Technical Details

### Context Propagation

```go
// Context flows through execution chain
cmdCtx (main.go)
  → exec.ExecuteCommand(cmdCtx, ...)
    → executeOSCommandLocal(cmdCtx, ...)
      → exec.CommandContext(cmdCtx, "bash", "-c", command)
```

When `cmdCancel()` is called:
1. `cmdCtx.Done()` closes
2. `exec.CommandContext` kills the process
3. Goroutines reading output exit
4. Function returns with partial output

### SSH Context Cancellation

For SSH commands:
```go
// SSH session respects context
session.Start(command)

// When context cancelled:
session.Signal(ssh.SIGTERM)  // Send TERM signal
session.Close()               // Close session
```

## Troubleshooting

### ESC Not Working

1. **Check Terminal Mode**: Ensure terminal is in raw mode (automatic in yastop)
2. **Test ESC Key**: Try pressing ESC during command input (should cancel input)
3. **Check Keyboard**: Some terminals may intercept ESC

### Command Keeps Running

1. **Check Process**: Use `ps aux | grep command` to see if process is still running
2. **Manual Kill**: If needed, `kill -9 <pid>` from another terminal
3. **Report Issue**: If this happens consistently, it's a bug

### Slow Cancellation

1. **SSH Latency**: Normal for SSH connections (network delay)
2. **Process Cleanup**: Some processes take time to clean up resources
3. **Wait**: yastop waits up to 500ms before returning

## Summary

The ESC key provides a clean way to cancel long-running commands without exiting yastop. It uses Go's context cancellation mechanism to gracefully terminate commands and return to the monitoring interface.

**Key Points:**
- ✅ Press ESC anytime during command execution
- ✅ Immediate response (< 500ms)
- ✅ Partial output is saved
- ✅ Works for both local and SSH commands
- ✅ Clean return to monitoring interface
