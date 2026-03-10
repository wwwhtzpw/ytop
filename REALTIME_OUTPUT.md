# Real-Time Output Implementation

## Changes Made

### 1. Local Command Execution (`internal/executor/executor.go`)
- Modified `executeOSCommandLocal()` to read output byte-by-byte
- Immediately writes each byte to stdout/stderr without buffering
- Collects output in a buffer for saving to file

### 2. SSH Command Execution (`internal/connector/ssh.go`)
- Added `ExecuteCommandRealtime()` method
- Reads SSH command output byte-by-byte
- Immediately displays output as it arrives

### 3. Main Loop (`cmd/yastop/main.go`)
- Updated 's' key handler to not duplicate output
- Output is displayed in real-time during execution
- Only saves to file after completion

## How It Works

### Byte-by-Byte Reading
```go
go func() {
    buf := make([]byte, 1)
    for {
        n, err := stdout.Read(buf)
        if n > 0 {
            // Write to stdout immediately (no buffering)
            os.Stdout.Write(buf[:n])
            // Also save to buffer for file output
            bufferMutex.Lock()
            outputBuffer.Write(buf[:n])
            bufferMutex.Unlock()
        }
        if err != nil {
            break
        }
    }
    done <- true
}()
```

### Key Points
1. **No Line Buffering**: Reads 1 byte at a time to avoid waiting for newlines
2. **Immediate Display**: Uses `os.Stdout.Write()` directly (no fmt.Print buffering)
3. **Thread-Safe**: Uses mutex to protect shared output buffer
4. **Dual Purpose**: Displays in real-time AND saves for file output

## Testing

### Test 1: Simple Script
```bash
# Build
go build -o yastop ./cmd/yastop

# Run in monitoring mode
./yastop

# Press 's' and enter:
./test_simple_realtime.sh

# You should see output appear line by line with 1-second delays
```

### Test 2: iostat Command
```bash
# In monitoring mode, press 's' and enter:
iostat 3 3

# You should see:
# - First sample immediately
# - Second sample after 3 seconds
# - Third sample after 6 seconds
# Each sample displays as soon as it's generated
```

### Test 3: SSH Mode
```bash
# Connect via SSH
./yastop -h 10.10.10.130 -u username

# Press 's' and enter:
iostat 3 3

# Output should stream in real-time from remote host
```

### Test 4: Long-Running Command
```bash
# Press 's' and enter:
ping -c 10 google.com

# Each ping response should appear immediately
```

## Expected Behavior

### Before (Buffered Output)
```
[User presses 's']
Enter command: iostat 3 3
[Wait 9 seconds...]
[All output appears at once]
```

### After (Real-Time Output)
```
[User presses 's']
Enter command: iostat 3 3
[First sample appears immediately]
[3 seconds pass...]
[Second sample appears]
[3 seconds pass...]
[Third sample appears]
```

## Troubleshooting

### If output still appears buffered:

1. **Check Terminal Mode**: Ensure terminal is in raw mode (already handled by yastop)

2. **Test with Simple Command**:
   ```bash
   # This should show output line by line
   for i in 1 2 3; do echo "Line $i"; sleep 1; done
   ```

3. **Check Command Output**: Some commands (like `iostat`) may buffer their own output. Try:
   ```bash
   # Force unbuffered output
   stdbuf -o0 iostat 3 3
   ```

4. **Debug Mode**: Run with debug to see execution flow:
   ```bash
   ./yastop --debug
   ```

## Performance Considerations

### Byte-by-Byte Reading
- **Pros**: True real-time display, no line buffering delays
- **Cons**: More system calls (negligible for human-readable output)

### Alternative: Chunk Reading
If performance is a concern for high-volume output, can change to:
```go
buf := make([]byte, 4096)  // Read 4KB chunks
```

But for typical monitoring commands (iostat, vmstat, etc.), byte-by-byte is fine.

## File Output

Output is still saved to file after command completes:
- Filename: `output_<command>.txt`
- Contains complete output from start to finish
- Saved even if command fails

## Limitations

1. **Interactive Commands**: Commands requiring user input won't work
2. **Terminal Control**: Commands using ncurses/terminal control may not display correctly
3. **Binary Output**: Binary data will be written as-is (may corrupt terminal)

## Recommended Commands

### Good (Real-Time Friendly)
- `iostat 1 5` - I/O statistics
- `vmstat 1 5` - Virtual memory statistics
- `ping -c 10 host` - Network ping
- `tail -f logfile` - Follow log file (use Ctrl+C to stop)
- Custom scripts with periodic output

### Avoid
- `top` - Interactive, uses terminal control
- `vi`, `nano` - Interactive editors
- `less`, `more` - Interactive pagers
- Commands without time limit (e.g., `iostat 1` without count)

## Summary

The implementation now provides true real-time output streaming for both local and SSH command execution. Output appears character-by-character as it's generated, giving immediate feedback for long-running monitoring commands.
