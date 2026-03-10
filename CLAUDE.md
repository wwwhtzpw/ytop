# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ytop** is a real-time performance monitoring CLI tool for YashanDB, similar to Oracle's oratop. It displays live database metrics in the terminal, including system statistics (v$sysstat), top wait events (v$system_event), and session-level metrics.

## Architecture

The project follows a modular architecture with clear separation of concerns:

```
Connector → Collector → Calculator → Display
```

- **Connector**: Abstracts database access via yasql CLI (local or SSH)
- **Collector**: Executes SQL queries to gather metrics from v$ views
- **Calculator**: Computes deltas, per-second rates, and TOP N rankings
- **Display**: Renders TUI with tables and panels using bubbletea/tview

## Key Technical Decisions

### Database Access
- Uses **yasql CLI** (not native driver) via `os/exec` or SSH
- Supports two connection modes:
  - **Local**: `yasql / as sysdba` or `yasql sys/password`
  - **SSH**: SSH to jumphost → `source env.sh` → execute yasql
- SSH implementation uses `golang.org/x/crypto/ssh`

### Data Collection
Four main data sources:
1. **v$sysstat**: 14 metrics showing per-second change rates
2. **v$system_event**: TOP 5 wait events by time
3. **v$sesstat + v$statname**: Session-level metrics (TOP N by configurable column, default: DB TIME)
4. **Session details**: Active sessions with sid_tid, event, username, sql_id, exec_time, program, client

### Metrics Calculation
- **v$sysstat**: `delta_per_sec = (value_cur - value_prev) / interval_sec`
- **v$system_event**: Sort by wait time, take TOP 5 (using delta between snapshots)
- **Session metrics**: Sort by user-specified column (default: DB TIME), take TOP N
- **Session details**: Already sorted by exec_time DESC in SQL, take TOP N rows

## Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `connection_mode` | `local` or `ssh` | - |
| `yasql_path` | Path to yasql executable | `yasql` |
| `connect_string` | Connection string (e.g., `"/ as sysdba"`) | - |
| `ssh_host` | SSH jumphost (required if mode=ssh) | - |
| `ssh_user` | SSH username | - |
| `ssh_key_file` / `ssh_password` | SSH authentication | - |
| `source_cmd` | Command to source env (e.g., `source /opt/yashandb/conf/yasdb.env`) | - |
| `interval` | Refresh interval in seconds | 1 |
| `count` | Number of iterations (0 = infinite) | 0 |
| `output_file` | Append output to file | - |
| `session_top_n` | Number of sessions to show in TOP N | 10 |
| `session_sort_by` | Session sort column | `DB TIME` |
| `session_detail_top_n` | Number of active sessions to show | 10 |

## CLI Usage

```bash
# Default: 1 second interval, continuous
yashandb-monitor

# Custom interval, continuous
yashandb-monitor 2

# Interval + count (like iostat)
yashandb-monitor 1 20

# With output file
yashandb-monitor -o monitor.log

# Custom session TOP settings
yashandb-monitor --session-top 20 --session-sort "CPU TIME"
```

## Project Structure

```
yashandb-monitor/
├── cmd/yashandb-monitor/
│   └── main.go              # Entry point: parse args, init connector & TUI, main loop
├── internal/
│   ├── connector/
│   │   ├── interface.go     # Interface: ExecuteSQL(sql) -> rows
│   │   ├── local.go         # Local yasql via os/exec
│   │   └── ssh.go           # SSH + source + yasql
│   ├── collector/
│   │   ├── sysstat.go       # Collect v$sysstat
│   │   ├── system_event.go  # Collect v$system_event
│   │   ├── sesstat.go       # Collect v$sesstat + v$statname
│   │   └── session_detail.go # Collect session details (session+process+exec_time)
│   ├── calculator/
│   │   ├── sysstat_delta.go # Compute per-second deltas
│   │   ├── top_events.go    # Sort TOP 5 events
│   │   └── session_top.go   # Sort session TOP N
│   └── display/
│       └── tui.go           # TUI rendering with tables/panels
├── config.example.ini       # Example configuration
├── go.mod
└── README.md
```

## Implementation Guidelines

### When Writing Connector Code
- Parse yasql stdout output (fixed-width or CSV format)
- Handle both local `os/exec` and SSH session execution
- For SSH: establish session → source env → execute yasql → parse output
- Consider reusing SSH connections to reduce latency

### When Writing Collector Code
- Query v$sysstat with specific name list (14 metrics)
- Query v$system_event sorted by wait time
- Join v$sesstat + v$statname for session-level metrics
- Query session details joining v$session + v$process (or equivalent YashanDB views)
- Return raw row data for Calculator to process

### When Writing Calculator Code
- Store previous snapshot for delta calculation
- Use actual time difference (not just interval config) to avoid drift
- For session metrics: sort by configurable column, take TOP N
- For session details: already sorted by SQL, just take first N rows

### When Writing Display Code
- Use bubbletea or tview for TUI
- Layout sections: title → sysstat table → TOP 5 events → session TOP N → session details
- Support output to file (append each refresh with timestamp)
- Handle Ctrl+C and 'q' for exit
- Show progress if count is specified (e.g., "5 / 20")

### YashanDB-Specific Considerations
- Column names in v$sysstat, v$system_event may differ from Oracle
- Session/process view names may be v$session/v$process (not gv$ for single instance)
- Date functions and time calculations need YashanDB syntax
- Verify view column names against YashanDB documentation
- User needs DBA or monitoring role to query v$ views

## Development Workflow

1. Implement Connector (local + SSH modes)
2. Implement Collectors (4 data sources)
3. Implement Calculator (deltas, TOP N sorting)
4. Implement Display (TUI layout)
5. Wire up main loop with interval/count/output_file support
6. Add configuration file parsing and CLI argument handling

## Cross-Platform Notes

- Go 1.19+ for single binary distribution
- Cross-compile for Linux/Windows/macOS
- No runtime dependencies on target machine (except yasql)
- Target machine must have yasql accessible (locally or via SSH)

## Important Reminders

- This tool does NOT embed YashanDB client libraries
- It calls external yasql command and parses text output
- Refresh interval should balance real-time needs vs database load
- Output file should include timestamps/separators for each sample
- All SQL queries must be verified against YashanDB documentation
