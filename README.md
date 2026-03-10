# ytop - YashanDB Performance Monitor

A real-time performance monitoring tool for YashanDB, similar to Oracle's oratop. Displays live database metrics in the terminal including system statistics, top wait events, and session-level information.

## Features

- **Real-time Monitoring**: Display v$sysstat metrics with per-second change rates
- **Top Wait Events**: Show TOP N wait events from v$system_event
- **Session Metrics**: Display session-level statistics with configurable sorting
- **Active Sessions**: Show detailed information about currently active sessions
- **Flexible Connection**: Support both local and SSH-based connections
- **Configurable Output**: Save monitoring data to file for later analysis
- **Cross-platform**: Single binary, works on Linux, macOS, and Windows

## Installation

### Prerequisites

- Go 1.19 or later
- Access to YashanDB with yasql client installed
- Appropriate database privileges (DBA or monitoring role)

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yihan/ytop.git
cd ytop

# Install dependencies
go mod download

# Build
go build -o ytop ./cmd/ytop

# Install (optional)
go install ./cmd/ytop
```

## Usage

### Basic Usage

```bash
# Default: 1 second interval, continuous monitoring
./ytop

# Custom interval (2 seconds)
./ytop 2

# Interval + count (like iostat: 1 second interval, 20 iterations)
./ytop 1 20
```

### SSH Connection

```bash
# Using command line flags
./ytop -ssh-host 10.10.10.130 -ssh-user yashan -ssh-password oracle

# Using config file
./ytop -config config.ini
```

### Advanced Options

```bash
# Save output to file
./ytop -o monitor.log

# Custom session TOP settings
./ytop -session-top 20 -session-sort "CPU TIME"

# Disable colors
./ytop -no-color

# Debug mode
./ytop -debug
```

### Configuration File

Create a configuration file (e.g., `config.ini`):

```ini
connection_mode = ssh
ssh_host = 10.10.10.130
ssh_user = yashan
ssh_password = oracle
connect_string = sys/Yashan!1
interval = 1
session_top_n = 10
```

Then run:

```bash
./ytop -config config.ini
```

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `-mode` | Connection mode: local or ssh | ssh |
| `-yasql` | Path to yasql executable | yasql |
| `-connect` | Connection string | sys/Yashan!1 |
| `-ssh-host` | SSH host | - |
| `-ssh-port` | SSH port | 22 |
| `-ssh-user` | SSH user | - |
| `-ssh-password` | SSH password | - |
| `-ssh-key` | SSH private key file | - |
| `-source` | Source command before yasql | - |
| `-i` | Refresh interval (seconds) | 1 |
| `-c` | Number of iterations (0=infinite) | 0 |
| `-o` | Output file path | - |
| `-session-top` | Number of sessions in TOP N | 10 |
| `-session-sort` | Session sort column | DB TIME |
| `-session-detail-top` | Number of active sessions | 10 |
| `-no-color` | Disable color output | false |
| `-no-timestamp` | Hide timestamp | false |
| `-debug` | Enable debug mode | false |

## Display Sections

### 1. v$SYSSTAT Metrics
Shows 14 key system statistics with current values and per-second change rates:
- DB TIME, CPU TIME
- COMMITS, REDO SIZE
- QUERY COUNT, BLOCK CHANGES
- LOGONS TOTAL, INSERT COUNT
- PARSE COUNT (HARD)
- DISK READS, DISK WRITES
- BUFFER GETS, EXECUTE COUNT
- BUFFER CR GETS

### 2. v$SYSTEM_EVENT TOP N
Displays top wait events sorted by wait time:
- Event name
- Total waits
- Time waited
- Average wait time
- Percentage

### 3. Session Metrics TOP N
Shows session-level statistics for top sessions:
- SID, Serial#, Username
- Key metrics: DB TIME, CPU TIME, BUFFER GETS, DISK READS, EXECUTE COUNT

### 4. Active Sessions
Displays detailed information about currently active sessions:
- SID.Serial
- Current wait event
- Username
- SQL ID
- Execution time
- Program
- Client

## Requirements

### Database Privileges

The monitoring user needs access to the following views:
- V$SYSSTAT
- V$SYSTEM_EVENT
- V$SESSION
- V$SESSTAT
- V$STATNAME

Typically requires DBA role or specific grants:

```sql
GRANT SELECT ON V$SYSSTAT TO monitoring_user;
GRANT SELECT ON V$SYSTEM_EVENT TO monitoring_user;
GRANT SELECT ON V$SESSION TO monitoring_user;
GRANT SELECT ON V$SESSTAT TO monitoring_user;
GRANT SELECT ON V$STATNAME TO monitoring_user;
```

## Examples

### Monitor local database

```bash
./ytop -mode local -connect "/ as sysdba"
```

### Monitor remote database via SSH

```bash
./ytop \
  -ssh-host 10.10.10.130 \
  -ssh-user yashan \
  -ssh-password oracle \
  -connect "sys/Yashan!1" \
  -i 2 \
  -o /tmp/monitor.log
```

### Monitor with custom session sorting

```bash
./ytop \
  -ssh-host 10.10.10.130 \
  -ssh-user yashan \
  -ssh-password oracle \
  -session-sort "BUFFER GETS" \
  -session-top 20
```

## Troubleshooting

### Connection Issues

1. **SSH connection fails**: Verify SSH credentials and network connectivity
2. **yasql not found**: Ensure yasql is in PATH or specify full path with `-yasql`
3. **Permission denied**: Check database user privileges

### Debug Mode

Enable debug mode to see detailed SQL queries and output:

```bash
./ytop -debug
```

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Author

Yihan
