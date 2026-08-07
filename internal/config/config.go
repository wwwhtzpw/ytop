package config

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/yihan/ytop/internal/logger"
	"gopkg.in/ini.v1"
)

// Config holds all configuration parameters
type Config struct {
	// Connection settings
	ConnectionMode string // "local" or "ssh"
	YasqlPath      string
	ConnectString  string

	// SSH settings
	SSHHost     string
	SSHPort     int
	SSHUser     string
	SSHPassword string
	SSHKeyFile  string
	SourceCmd   string

	// SSHSourceExistenceCheck is a remote `test -f <path>` fragment produced when -s is a simple env file path (SSH mode).
	// Executed once in SSHConnector.Connect; empty when using a custom shell snippet or local mode.
	SSHSourceExistenceCheck string

	// Display settings
	Interval          int
	Count             int
	OutputFile        string
	SessionTopN       int
	SessionSortBy     string
	SessionDetailTopN int
	ShowTimestamp     bool
	ColorEnabled      bool
	InstanceID        int  // 0 = all instances, 1,2,... = specific instance
	SessionWideMode   bool // --wide: show all 20 session metrics (default short: 15 core)

	// Metric settings
	SysStatMetrics     []string // GV$SYSSTAT names to query (includes source-only TIME metrics)
	SessionStatMetrics []string // GV$SESSTAT names for session TOP N
	EventTopN          int

	// Advanced settings
	QueryTimeout int
	SSHTimeout   int
	ReuseSSH     bool
	DebugMode    bool

	// Direct execution mode (non-interactive)
	ExecuteScript string // -f: script file to execute
	ExecuteSQL    string // -q: SQL query to execute
	EnterCLI      bool   // -e/--enter: interactive DB CLI session
	JdbcEnter     bool   // -E/--jdbc-enter: local JDBC shell (yjdbc)
	JdbcJar       string // -J/--jdbc-jar: JDBC driver jar
	DbName        string // --dbname for JDBC URL (default yasdb when -E)
	// Jdbc* 仅由 -E 从 CLI 填入, 禁止用 ini 的 ssh_* 冒充
	JdbcHost        string
	JdbcPort        int
	JdbcUser        string
	JdbcPassword    string
	JdbcPasswordSet bool   // visited -p/--ssh-password (允许空串)
	JdbcPortSet     bool   // visited -P/--port
	ReadScript      string // -r: read/view script content
	CopyScript      string // -c: copy script (format: "script dest")
	FindScript      string // -S: find/search scripts (pattern; empty means all)
	FindScriptSet   bool   // true when -S was passed on the command line

	// Metric mode (delta/per-second calculation)
	MetricMode bool // --metric: enable metric collection with delta calculation

	// Database type
	DBType string // "yashandb", "oracle", "dameng", "mysql", "postgresql", "mssql"

	// DBVersion is the target database version for script resolution (empty = auto-detect via CLI -v).
	DBVersion string

	// Custom login command (overrides default CLI login)
	LoginCmd string

	// TargetOS is the OS of the machine where SQL is executed.
	//   "unix"    — Linux/macOS/AIX (default)
	//   "windows" — Remote Windows via SSH
	// For local mode: derived from runtime.GOOS by the connector.
	// For SSH mode: auto-detected during Connect(); can be overridden with --target-os.
	TargetOS string

	// RemoteTempDir is the absolute temp directory on the SSH target host.
	// Populated during SSHConnector.Connect (echo %TEMP% on Windows, /tmp on Unix).
	RemoteTempDir string

	// RemoteCLIPath is the absolute path to the DB CLI after Connect (local or SSH target).
	// Populated by LocalConnector/SSHConnector Connect (which/where, optionally after -s).
	RemoteCLIPath string

	// C / Python source execution (-f memtest.c / probe.py)
	CC      string // C compiler (default gcc)
	CFLAGS  string // C compiler flags
	LDFLAGS string // C linker flags (e.g. -lm)
	Python  string // Python interpreter; empty = auto-detect on target

	// Set when interval/count come from INI (direct mode should not reset them).
	iniIntervalSet       bool
	iniCountSet          bool
	iniConnectionModeSet bool
	iniSessionTopSet     bool
}

// Sysstat metric name constants (GV$SYSSTAT.NAME in YashanDB).
const (
	MetricDiskReadTime         = "DISK READ TIME"
	MetricDiskWriteTime        = "DISK WRITE TIME"
	MetricDiskReads            = "DISK READS"
	MetricDiskWrites           = "DISK WRITES"
	MetricCheckpointsCompleted = "CHECKPOINTS COMPLETED"
	MetricUserIOWaitTime       = "USER IO WAIT TIME"
	MetricVMOpen               = "VM OPEN"
	MetricVMSwapOut            = "VM SWAP OUT"
	DerivedAvgReadMS           = "AVG READ MS"
	DerivedAvgWriteMS          = "AVG WRITE MS"
)

// defaultCoreStatMetrics are the original 14 instance/session statistics.
func defaultCoreStatMetrics() []string {
	return []string{
		"DB TIME",
		"CPU TIME",
		"COMMITS",
		"REDO SIZE",
		"QUERY COUNT",
		"BLOCK CHANGES",
		"LOGONS TOTAL",
		"INSERT COUNT",
		"PARSE COUNT (HARD)",
		"DISK READS",
		"DISK WRITES",
		"BUFFER GETS",
		"EXECUTE COUNT",
		"BUFFER CR GETS",
	}
}

// defaultSessionStatMetrics lists GV$SESSTAT names for session TOP N (includes TIME for derived IO avg).
func defaultSessionStatMetrics() []string {
	return defaultSysStatQueryMetrics()
}

// SessionStatDisplayNames is the session TOP metric column order (aligned with instance sysstat row).
// Used by calculator for zero-metric init — always returns full list.
func SessionStatDisplayNames() []string {
	return SysStatDisplayNames()
}

// SessionStatShortDisplayNames is the short-mode session TOP metric column order (15 core metrics).
// Drops CHECKPOINTS COMPLETED, VM OPEN, VM SWAP OUT (instance-level, session-almost-always-0),
// plus LOGONS TOTAL and PARSE COUNT (HARD).
func SessionStatShortDisplayNames() []string {
	return []string{
		"DB TIME",
		"CPU TIME",
		"COMMITS",
		"REDO SIZE",
		"QUERY COUNT",
		"BLOCK CHANGES",
		"INSERT COUNT",
		"DISK READS",
		"AVG READ MS",
		"DISK WRITES",
		"AVG WRITE MS",
		"BUFFER GETS",
		"EXECUTE COUNT",
		"BUFFER CR GETS",
		"USER IO WAIT TIME",
	}
}

// defaultSysStatQueryMetrics lists all GV$SYSSTAT names collected in monitor mode.
func defaultSysStatQueryMetrics() []string {
	base := defaultCoreStatMetrics()
	extra := []string{
		MetricCheckpointsCompleted,
		MetricUserIOWaitTime,
		MetricDiskReadTime,
		MetricDiskWriteTime,
		MetricVMOpen,
		MetricVMSwapOut,
	}
	out := make([]string, 0, len(base)+len(extra))
	out = append(out, base...)
	out = append(out, extra...)
	return out
}

// SysStatDisplayNames is the single monitor TUI row (rates + IO latency ms).
func SysStatDisplayNames() []string {
	return []string{
		"DB TIME",
		"CPU TIME",
		"COMMITS",
		"REDO SIZE",
		"QUERY COUNT",
		"BLOCK CHANGES",
		"LOGONS TOTAL",
		"INSERT COUNT",
		"PARSE COUNT (HARD)",
		MetricDiskReads,
		DerivedAvgReadMS,
		MetricDiskWrites,
		DerivedAvgWriteMS,
		"BUFFER GETS",
		"EXECUTE COUNT",
		"BUFFER CR GETS",
		MetricCheckpointsCompleted,
		MetricUserIOWaitTime,
		MetricVMOpen,
		MetricVMSwapOut,
	}
}

// IsSysStatSourceOnly reports metrics queried but not shown directly in the TUI.
func IsSysStatSourceOnly(name string) bool {
	return name == MetricDiskReadTime || name == MetricDiskWriteTime
}

// SessionStatMetricsList returns session-level stat names for GV$SESSTAT.
func (c *Config) SessionStatMetricsList() []string {
	if len(c.SessionStatMetrics) > 0 {
		return c.SessionStatMetrics
	}
	return defaultSessionStatMetrics()
}

// DefaultConfig returns a config with default values
func DefaultConfig() *Config {
	return &Config{
		ConnectionMode:     "local", // Default to local mode
		YasqlPath:          "yasql",
		ConnectString:      defaultOracleConnectString,
		SSHPort:            22,
		Interval:           5,
		Count:              0,
		SessionTopN:        10,
		SessionSortBy:      "DB TIME",
		SessionDetailTopN:  10,
		ShowTimestamp:      true,
		ColorEnabled:       true,
		InstanceID:         0, // 0 = all instances
		SysStatMetrics:     defaultSysStatQueryMetrics(),
		SessionStatMetrics: defaultSessionStatMetrics(),
		EventTopN:          5,
		QueryTimeout:       30,
		SSHTimeout:         10,
		ReuseSSH:           true,
		DebugMode:          false,
		DBType:             "yashandb",
		CC:                 "gcc",
		Python:             "", // empty: auto-detect on target
	}
}

// ResolveCLIForExec returns the CLI executable to invoke: RemoteCLIPath when set after Connect, else DefaultCLI().
func (c *Config) ResolveCLIForExec() string {
	if c.RemoteCLIPath != "" {
		return c.RemoteCLIPath
	}
	return c.DefaultCLI()
}

// DefaultCLI returns the default CLI tool name for the given DB type
func (c *Config) DefaultCLI() string {
	switch c.DBType {
	case "oracle":
		return "sqlplus"
	case "dameng":
		return "disql"
	case "mysql":
		return "mysql"
	case "postgresql":
		return "psql"
	case "mssql":
		return "sqlcmd"
	default:
		return c.YasqlPath
	}
}

const defaultOracleConnectString = "/ as sysdba"

// IsOracleStyleConnectString reports whether s is an Oracle/YashanDB sqlplus-style connect string.
func IsOracleStyleConnectString(s string) bool {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return false
	}
	lower := strings.ToLower(trimmed)
	return lower == defaultOracleConnectString ||
		lower == "/ as sysoper" ||
		strings.HasPrefix(lower, "/ as sys")
}

// ApplyDBTypeConnectDefaults adjusts ConnectString for the selected DB CLI.
func (c *Config) ApplyDBTypeConnectDefaults() {
	if c.LoginCmd != "" {
		return
	}
	switch c.DBType {
	case "mysql", "postgresql", "mssql":
		if IsOracleStyleConnectString(c.ConnectString) {
			c.ConnectString = ""
		}
	}
}

const defaultMssqlSSHWindowsConnectString = "-S localhost -E"

// ApplyMssqlSSHWindowsConnectDefaults sets sqlcmd Windows integrated auth for SSH remotes
// when the user did not pass -C/--connect (ConnectString empty after DB-type cleanup).
// Call after TargetOS is known (SSH Connect).
func (c *Config) ApplyMssqlSSHWindowsConnectDefaults() {
	if c.LoginCmd != "" {
		return
	}
	if c.DBType != "mssql" || c.ConnectionMode != "ssh" || c.TargetOS != "windows" {
		return
	}
	if strings.TrimSpace(c.ConnectString) != "" {
		return
	}
	c.ConnectString = defaultMssqlSSHWindowsConnectString
}

// ApplyMssqlRegistryPort patches default OS-auth ConnectString with a non-default TCP port from registry.
func (c *Config) ApplyMssqlRegistryPort(tcpPort string) {
	if c.LoginCmd != "" {
		return
	}
	if c.DBType != "mssql" || c.ConnectionMode != "ssh" || c.TargetOS != "windows" {
		return
	}
	port := strings.TrimSpace(tcpPort)
	if port == "" || port == "1433" {
		return
	}
	if strings.TrimSpace(c.ConnectString) != defaultMssqlSSHWindowsConnectString {
		return
	}
	c.ConnectString = fmt.Sprintf("-S localhost,%s -E", port)
}

// parseDBType normalizes db type shorthand to canonical name.
func parseDBType(s string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "y", "yas", "yashandb":
		return "yashandb", nil
	case "o", "ora", "oracle":
		return "oracle", nil
	case "d", "dm", "dameng":
		return "dameng", nil
	case "m", "my", "mysql":
		return "mysql", nil
	case "p", "pg", "postgres", "postgresql":
		return "postgresql", nil
	case "s", "ms", "mssql", "sqlserver":
		return "mssql", nil
	default:
		return "", fmt.Errorf("unknown database type %q (use y/o/d/m/p/s or yashandb/oracle/dameng/mysql/postgresql/mssql)", s)
	}
}

// normalizeFindScriptFlagArgs turns bare "-S" into "-S" "" so an empty pattern lists all scripts.
func normalizeFindScriptFlagArgs(args []string) []string {
	if len(args) <= 1 {
		return args
	}
	out := make([]string, 0, len(args)+1)
	out = append(out, args[0])
	for i := 1; i < len(args); i++ {
		out = append(out, args[i])
		if args[i] != "-S" {
			continue
		}
		hasValue := i+1 < len(args) && !strings.HasPrefix(args[i+1], "-")
		if !hasValue {
			out = append(out, "")
		}
	}
	return out
}

// LoadConfig loads configuration from file and command line
func LoadConfig() (*Config, error) {
	cfg := DefaultConfig()
	resetLoadTrace("main")

	// Customize flag error handling to show our custom usage
	flag.Usage = func() {
		PrintUsage()
	}

	// Define command line flags
	var explicitConfigPath string
	flag.StringVar(&explicitConfigPath, "config", "", "Path to config file")
	flag.StringVar(&explicitConfigPath, "c", "", "Path to config file (short)")
	connectionMode := flag.String("mode", "", "Connection mode: local or ssh")
	yasqlPath := flag.String("yasql", "", "Path to yasql executable")
	connectString := flag.String("connect", "", "Connection string")
	connectStringShort := flag.String("C", "", "Connection string (short)")
	sshHost := flag.String("ssh-host", "", "SSH host")
	sshHostShort := flag.String("t", "", "SSH host (short)")
	port := flag.Int("port", 0, "SSH port")
	portShort := flag.Int("P", 0, "SSH port (short)")
	sshUser := flag.String("ssh-user", "", "SSH user")
	sshUserShort := flag.String("u", "", "SSH user (short)")
	sshPassword := flag.String("ssh-password", "", "SSH password")
	sshPasswordShort := flag.String("p", "", "SSH password (short)")
	sshKeyFile := flag.String("ssh-key", "", "SSH private key file")
	sshKeyFileShort := flag.String("k", "", "SSH private key file (short)")
	sourceCmd := flag.String("source", "", "Source command to run before yasql")
	sourceCmdShort := flag.String("s", "", "Source command (short)")
	// Interval and count are now handled via positional arguments only
	// Removed -i and -c flags for simplicity
	outputFile := flag.String("o", "", "Output file path")
	sessionTopN := flag.Int("session-top", 0, "Number of sessions to show in TOP N")
	sessionSortBy := flag.String("session-sort", "", "Session sort column")
	sessionDetailTopN := flag.Int("session-detail-top", 0, "Number of active sessions to show")
	wideMode := flag.Bool("wide", false, "Show all 20 session metrics (default: 15 core metrics)")
	instanceID := flag.Int("inst-id", 0, "Instance ID (0 = all instances, 1,2,... = specific instance)")
	noColor := flag.Bool("no-color", false, "Disable color output")
	noTimestamp := flag.Bool("no-timestamp", false, "Hide timestamp")
	debug := flag.Bool("debug", false, "Enable debug mode")
	debugShort := flag.Bool("D", false, "Enable debug mode (short)")
	executeScript := flag.String("f", "", "Execute script file directly (non-interactive mode)")
	executeSQL := flag.String("q", "", "Execute SQL query directly (non-interactive mode)")
	enterCLI := flag.Bool("e", false, "Enter interactive DB CLI (PTY; Unix local/SSH only)")
	enterCLILong := flag.Bool("enter", false, "Enter interactive DB CLI (PTY; Unix local/SSH only)")
	jdbcEnter := flag.Bool("E", false, "Enter local JDBC shell (yjdbc; control host only)")
	jdbcEnterLong := flag.Bool("jdbc-enter", false, "Enter local JDBC shell (yjdbc; control host only)")
	jdbcJar := flag.String("jdbc-jar", "", "JDBC driver jar (optional with -E if embedded)")
	jdbcJarShort := flag.String("J", "", "JDBC driver jar (short; optional with -E if embedded)")
	dbName := flag.String("dbname", "", "Database name for JDBC URL (default yasdb with -E)")
	readScript := flag.String("r", "", "Read/view script content (non-interactive mode)")
	copyScript := flag.String("copy", "", "Copy script to destination (format: 'script dest', non-interactive mode)")
	findScript := flag.String("S", "", "Find/search scripts by pattern (non-interactive mode)")
	metricMode := flag.Bool("m", false, "Enable metric mode with delta/per-second calculation (use with -f)")
	metricModeLong := flag.Bool("metric", false, "Enable metric mode with delta/per-second calculation (use with -f)")
	dbType := flag.String("d", "", "Database type: y/yas/yashandb, o/ora/oracle, d/dm/dameng, m/my/mysql, p/pg/postgres, s/ms/mssql")
	dbTypeLong := flag.String("db-type", "", "Database type (long form)")
	dbVersionShort := flag.String("V", "", "Database version for script resolution (short; empty = auto-detect via DB CLI -v)")
	dbVersion := flag.String("db-version", "", "Database version for script resolution (empty = auto-detect via DB CLI -v)")
	loginCmd := flag.String("login-cmd", "", "Custom login command (e.g. 'sqlplus / as sysdba')")
	targetOS := flag.String("target-os", "", "Remote OS type for SSH mode: windows or unix (default: auto-detect)")
	cc := flag.String("cc", "", "C compiler for -f *.c (default: gcc)")
	cflags := flag.String("cflags", "", "C compiler flags for -f *.c")
	ldflags := flag.String("ldflags", "", "C linker flags for -f *.c (e.g. -lm)")
	python := flag.String("python", "", "Python for -f *.py (default: auto-detect on target)")

	if err := flag.CommandLine.Parse(normalizeFindScriptFlagArgs(os.Args)[1:]); err != nil {
		return nil, err
	}

	visited := make(map[string]bool)
	flag.Visit(func(f *flag.Flag) {
		visited[f.Name] = true
	})
	recordCLIOverrides(visited)

	// Load INI only when -c/--config is explicitly passed
	if err := LoadINIInto(cfg, resolveExplicitConfigPath(visited, explicitConfigPath)); err != nil {
		return nil, fmt.Errorf("failed to load config file: %w", err)
	}

	// Override with explicitly passed command line flags only
	if VisitedAny(visited, "mode") && *connectionMode != "" {
		cfg.ConnectionMode = *connectionMode
	}
	if VisitedAny(visited, "yasql") && *yasqlPath != "" {
		cfg.YasqlPath = *yasqlPath
	}
	if VisitedAny(visited, "connect") && *connectString != "" {
		cfg.ConnectString = *connectString
	}
	if VisitedAny(visited, "C") && *connectStringShort != "" {
		cfg.ConnectString = *connectStringShort
	}
	if VisitedAny(visited, "ssh-host") && *sshHost != "" {
		cfg.SSHHost = *sshHost
	}
	if VisitedAny(visited, "t") && *sshHostShort != "" {
		cfg.SSHHost = *sshHostShort
	}
	if VisitedAny(visited, "port") && *port != 0 {
		cfg.SSHPort = *port
	}
	if VisitedAny(visited, "P") && *portShort != 0 {
		cfg.SSHPort = *portShort
	}
	if VisitedAny(visited, "ssh-user") && *sshUser != "" {
		cfg.SSHUser = *sshUser
	}
	if VisitedAny(visited, "u") && *sshUserShort != "" {
		cfg.SSHUser = *sshUserShort
	}
	if VisitedAny(visited, "ssh-password") && *sshPassword != "" {
		cfg.SSHPassword = *sshPassword
	}
	if VisitedAny(visited, "p") && *sshPasswordShort != "" {
		cfg.SSHPassword = *sshPasswordShort
	}
	if VisitedAny(visited, "ssh-key") && *sshKeyFile != "" {
		cfg.SSHKeyFile = *sshKeyFile
	}
	if VisitedAny(visited, "k") && *sshKeyFileShort != "" {
		cfg.SSHKeyFile = *sshKeyFileShort
	}
	if VisitedAny(visited, "source") && *sourceCmd != "" {
		cfg.SourceCmd = *sourceCmd
	}
	if VisitedAny(visited, "s") && *sourceCmdShort != "" {
		cfg.SourceCmd = *sourceCmdShort
	}
	if VisitedAny(visited, "o") && *outputFile != "" {
		cfg.OutputFile = *outputFile
	}
	if VisitedAny(visited, "session-top") && *sessionTopN > 0 {
		cfg.SessionTopN = *sessionTopN
	}
	if VisitedAny(visited, "session-sort") && *sessionSortBy != "" {
		cfg.SessionSortBy = *sessionSortBy
	}
	if VisitedAny(visited, "session-detail-top") && *sessionDetailTopN > 0 {
		cfg.SessionDetailTopN = *sessionDetailTopN
	}
	if VisitedAny(visited, "no-color") && *noColor {
		cfg.ColorEnabled = false
	}
	if VisitedAny(visited, "no-timestamp") && *noTimestamp {
		cfg.ShowTimestamp = false
	}
	if VisitedAny(visited, "wide") && *wideMode {
		cfg.SessionWideMode = true
	}
	if VisitedAny(visited, "debug", "D") && (*debug || *debugShort) {
		cfg.DebugMode = true
	}
	if VisitedAny(visited, "inst-id") {
		cfg.InstanceID = *instanceID
	}
	if VisitedAny(visited, "f") && *executeScript != "" {
		cfg.ExecuteScript = *executeScript
	}
	if VisitedAny(visited, "q") && *executeSQL != "" {
		cfg.ExecuteSQL = *executeSQL
	}
	if VisitedAny(visited, "e", "enter") && (*enterCLI || *enterCLILong) {
		cfg.EnterCLI = true
	}
	if VisitedAny(visited, "E", "jdbc-enter") && (*jdbcEnter || *jdbcEnterLong) {
		cfg.JdbcEnter = true
	}
	if VisitedAny(visited, "jdbc-jar") && *jdbcJar != "" {
		cfg.JdbcJar = *jdbcJar
	}
	if VisitedAny(visited, "J") && *jdbcJarShort != "" {
		cfg.JdbcJar = *jdbcJarShort
	}
	if VisitedAny(visited, "dbname") && *dbName != "" {
		cfg.DbName = *dbName
	}
	if VisitedAny(visited, "r") && *readScript != "" {
		cfg.ReadScript = *readScript
	}
	if VisitedAny(visited, "copy") && *copyScript != "" {
		cfg.CopyScript = *copyScript
	}
	if VisitedAny(visited, "S") {
		cfg.FindScript = *findScript
		cfg.FindScriptSet = true
	}
	if VisitedAny(visited, "m", "metric") && (*metricMode || *metricModeLong) {
		cfg.MetricMode = true
	}
	if VisitedAny(visited, "db-type") && *dbTypeLong != "" {
		parsed, err := parseDBType(*dbTypeLong)
		if err != nil {
			return nil, err
		}
		cfg.DBType = parsed
	}
	if VisitedAny(visited, "d") && *dbType != "" {
		parsed, err := parseDBType(*dbType)
		if err != nil {
			return nil, err
		}
		cfg.DBType = parsed
	}
	if VisitedAny(visited, "V") && *dbVersionShort != "" {
		cfg.DBVersion = strings.TrimSpace(*dbVersionShort)
	}
	if VisitedAny(visited, "db-version") && *dbVersion != "" {
		cfg.DBVersion = strings.TrimSpace(*dbVersion)
	}
	if VisitedAny(visited, "login-cmd") && *loginCmd != "" {
		cfg.LoginCmd = *loginCmd
	}
	if VisitedAny(visited, "target-os") && *targetOS != "" {
		osName, err := parseTargetOS(*targetOS)
		if err != nil {
			return nil, err
		}
		cfg.TargetOS = osName
	}
	if VisitedAny(visited, "cc") && *cc != "" {
		cfg.CC = *cc
	}
	if VisitedAny(visited, "cflags") && *cflags != "" {
		cfg.CFLAGS = *cflags
	}
	if VisitedAny(visited, "ldflags") && *ldflags != "" {
		cfg.LDFLAGS = *ldflags
	}
	if VisitedAny(visited, "python") && *python != "" {
		cfg.Python = *python
	}

	cfg.ApplyDBTypeConnectDefaults()

	// -E: 从 CLI 填 JDBC 快照 (禁止 ini ssh_*), 并强制 local, 禁止自动切 ssh
	if cfg.JdbcEnter {
		fillJdbcEnterCLI(cfg, visited, sshHost, sshHostShort, port, portShort,
			sshUser, sshUserShort, sshPassword, sshPasswordShort)
		cfg.ConnectionMode = "local"
	}

	// Auto-detect connection mode when not explicitly set on CLI or in INI
	if !cfg.JdbcEnter && !VisitedAny(visited, "mode") && !cfg.iniConnectionModeSet && cfg.ConnectionMode == "local" && cfg.SSHHost != "" {
		cfg.ConnectionMode = "ssh"
	}

	if err := FinalizeSourceCmd(cfg); err != nil {
		return nil, err
	}

	// Handle positional arguments (interval [count])
	args := stripDebugFlagsFromArgs(flag.Args(), cfg)

	// Check if in direct execution mode (including metric mode with -f)
	isDirectMode := cfg.ExecuteScript != "" || cfg.ExecuteSQL != "" || cfg.ReadScript != "" ||
		cfg.CopyScript != "" || cfg.FindScriptSet || cfg.EnterCLI || cfg.JdbcEnter

	// Handle interval and count from positional arguments
	// Positional args: [interval] [count]
	// - Monitor mode: ytop [interval] [count]
	// - Direct mode: ytop -f xxx [interval] [count]
	// - Metric mode: ytop -f xxx -m [interval] [count]

	intervalSpecified := false
	countSpecified := false

	if len(args) >= 1 {
		if i, err := strconv.Atoi(args[0]); err == nil && i >= 0 {
			cfg.Interval = i
			intervalSpecified = true
		}
	}

	if len(args) >= 2 {
		if c, err := strconv.Atoi(args[1]); err == nil && c >= 0 {
			cfg.Count = c
			countSpecified = true
		}
	}

	// In direct execution mode (-f/-q/-r/-c/-S), if neither interval nor count specified,
	// execute once (interval=0, count=1). If interval is specified but count is not,
	// count defaults to 0 (infinite loop), consistent with monitor mode.
	// This applies to all direct modes including metric mode (-f xxx -m).
	if isDirectMode {
		if !intervalSpecified && !cfg.iniIntervalSet {
			cfg.Interval = 0
			if !countSpecified && !cfg.iniCountSet {
				cfg.Count = 1
			}
			recordMergeNote("direct_mode: default interval=0 count=1 (no ini/positional)")
		} else if !intervalSpecified && cfg.iniIntervalSet {
			recordMergeNote(fmt.Sprintf("direct_mode: interval=%d from ini", cfg.Interval))
		}
	}
	recordPositional(args, intervalSpecified, countSpecified)

	// -e/--enter 与其它直连执行模式互斥
	if cfg.EnterCLI {
		if cfg.JdbcEnter || cfg.ExecuteScript != "" || cfg.ExecuteSQL != "" || cfg.ReadScript != "" ||
			cfg.CopyScript != "" || cfg.FindScriptSet || cfg.MetricMode {
			return nil, fmt.Errorf("cannot combine -e/--enter with -E, -f, -q, -r, --copy, -S, or -m/--metric")
		}
	}
	// -E/--jdbc-enter: 允许搭配 -f SQL 脚本 (经 JDBC @ 执行); 其它动作仍互斥
	if cfg.JdbcEnter {
		if cfg.EnterCLI || cfg.ExecuteSQL != "" || cfg.ReadScript != "" ||
			cfg.CopyScript != "" || cfg.FindScriptSet || cfg.MetricMode {
			return nil, fmt.Errorf("cannot combine -E/--jdbc-enter with -e, -q, -r, --copy, -S, or -m/--metric")
		}
		if cfg.ExecuteScript != "" {
			name := firstCLIToken(cfg.ExecuteScript)
			if !strings.HasSuffix(strings.ToLower(name), ".sql") {
				return nil, fmt.Errorf("-E -f only supports SQL scripts (.sql), got %q", name)
			}
		}
	}

	// Validate configuration
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// LoadINIInto merges settings from an INI file into cfg when explicitPath is non-empty.
func LoadINIInto(cfg *Config, explicitPath string) error {
	path := strings.TrimSpace(explicitPath)
	if path == "" {
		recordNoINI()
		return nil
	}
	return loadFromFile(cfg, path)
}

// resolveExplicitConfigPath returns the config file path when -c/--config was passed.
func resolveExplicitConfigPath(visited map[string]bool, configPath string) string {
	if visited == nil {
		return ""
	}
	if visited["config"] || visited["c"] {
		return configPath
	}
	return ""
}

// iniLoadOptions controls INI parsing. SpaceBeforeInlineComment allows # and ; in
// values when not preceded by whitespace (e.g. passwords p@ss#word), while
// "value  # comment" and "value  ; comment" still strip trailing inline comments.
var iniLoadOptions = ini.LoadOptions{
	SpaceBeforeInlineComment: true,
}

// loadFromFile loads all supported keys from an INI file into cfg.
func loadFromFile(cfg *Config, path string) error {
	iniFile, err := ini.LoadSources(iniLoadOptions, path)
	if err != nil {
		return err
	}

	section := iniFile.Section("")

	setString := func(key string, set func(string)) {
		if section.HasKey(key) {
			set(section.Key(key).String())
		}
	}
	setInt := func(key string, set func(int)) {
		if section.HasKey(key) {
			set(section.Key(key).MustInt(0))
		}
	}
	setBool := func(key string, set func(bool)) {
		if !section.HasKey(key) {
			return
		}
		v, err := parseINIBool(section.Key(key).String())
		if err != nil {
			return
		}
		set(v)
	}

	setString("connection_mode", func(v string) {
		cfg.ConnectionMode = strings.TrimSpace(v)
		cfg.iniConnectionModeSet = true
	})
	setString("yasql_path", func(v string) { cfg.YasqlPath = v })
	setString("connect_string", func(v string) { cfg.ConnectString = v })

	setString("ssh_host", func(v string) { cfg.SSHHost = v })
	setInt("ssh_port", func(v int) { cfg.SSHPort = v })
	setString("ssh_user", func(v string) { cfg.SSHUser = v })
	setString("ssh_password", func(v string) { cfg.SSHPassword = v })
	setString("ssh_key_file", func(v string) { cfg.SSHKeyFile = v })
	setString("source_cmd", func(v string) { cfg.SourceCmd = v })

	if section.HasKey("interval") {
		cfg.Interval = section.Key("interval").MustInt(cfg.Interval)
		cfg.iniIntervalSet = true
	}
	if section.HasKey("count") {
		cfg.Count = section.Key("count").MustInt(cfg.Count)
		cfg.iniCountSet = true
	}

	setString("output_file", func(v string) { cfg.OutputFile = v })
	setInt("session_top_n", func(v int) {
		cfg.SessionTopN = v
		cfg.iniSessionTopSet = true
	})
	setString("session_sort_by", func(v string) { cfg.SessionSortBy = v })
	setInt("session_detail_top_n", func(v int) { cfg.SessionDetailTopN = v })

	setBool("show_timestamp", func(v bool) { cfg.ShowTimestamp = v })
	setBool("color_enabled", func(v bool) { cfg.ColorEnabled = v })
	if section.HasKey("no_color") {
		if v, err := parseINIBool(section.Key("no_color").String()); err == nil && v {
			cfg.ColorEnabled = false
		}
	}

	if section.HasKey("instance_id") {
		cfg.InstanceID = section.Key("instance_id").MustInt(0)
	} else if section.HasKey("inst_id") {
		cfg.InstanceID = section.Key("inst_id").MustInt(0)
	}

	if section.HasKey("sysstat_metrics") {
		metricsStr := section.Key("sysstat_metrics").String()
		if metricsStr != "" {
			parts := strings.Split(metricsStr, ",")
			cfg.SysStatMetrics = make([]string, 0, len(parts))
			for _, m := range parts {
				if t := strings.TrimSpace(m); t != "" {
					cfg.SysStatMetrics = append(cfg.SysStatMetrics, t)
				}
			}
		}
	}
	if section.HasKey("session_stat_metrics") {
		metricsStr := section.Key("session_stat_metrics").String()
		if metricsStr != "" {
			parts := strings.Split(metricsStr, ",")
			cfg.SessionStatMetrics = make([]string, 0, len(parts))
			for _, m := range parts {
				if t := strings.TrimSpace(m); t != "" {
					cfg.SessionStatMetrics = append(cfg.SessionStatMetrics, t)
				}
			}
		}
	}
	setInt("event_top_n", func(v int) { cfg.EventTopN = v })

	setInt("query_timeout", func(v int) {
		if v > 0 {
			cfg.QueryTimeout = v
		}
	})
	setInt("ssh_timeout", func(v int) {
		if v > 0 {
			cfg.SSHTimeout = v
		}
	})
	setBool("reuse_ssh", func(v bool) { cfg.ReuseSSH = v })
	setBool("debug", func(v bool) { cfg.DebugMode = v })
	setBool("debug_mode", func(v bool) { cfg.DebugMode = v })

	setString("execute_script", func(v string) { cfg.ExecuteScript = strings.TrimSpace(v) })
	setString("execute_sql", func(v string) { cfg.ExecuteSQL = strings.TrimSpace(v) })
	setString("read_script", func(v string) { cfg.ReadScript = strings.TrimSpace(v) })
	setString("copy_script", func(v string) { cfg.CopyScript = strings.TrimSpace(v) })
	if section.HasKey("find_script") {
		cfg.FindScript = section.Key("find_script").String()
		cfg.FindScriptSet = true
	}

	setBool("metric_mode", func(v bool) { cfg.MetricMode = v })
	setBool("metric", func(v bool) { cfg.MetricMode = v })

	if section.HasKey("db_type") {
		parsed, err := parseDBType(section.Key("db_type").String())
		if err != nil {
			return fmt.Errorf("config %q: %w", path, err)
		}
		cfg.DBType = parsed
	}
	setString("db_version", func(v string) { cfg.DBVersion = strings.TrimSpace(v) })
	setString("login_cmd", func(v string) { cfg.LoginCmd = v })

	if section.HasKey("target_os") {
		osName, err := parseTargetOS(section.Key("target_os").String())
		if err != nil {
			return fmt.Errorf("config %q: %w", path, err)
		}
		cfg.TargetOS = osName
	}

	setString("cc", func(v string) {
		if strings.TrimSpace(v) != "" {
			cfg.CC = v
		}
	})
	setString("cflags", func(v string) { cfg.CFLAGS = v })
	setString("ldflags", func(v string) { cfg.LDFLAGS = v })
	setString("python", func(v string) {
		if strings.TrimSpace(v) != "" {
			cfg.Python = v
		}
	})

	cfg.ApplyDBTypeConnectDefaults()

	keys := make([]string, 0, len(section.Keys()))
	for _, k := range section.Keys() {
		keys = append(keys, k.Name())
	}
	recordINILoaded(path, keys)
	return nil
}

func parseINIBool(s string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("invalid boolean %q", s)
	}
}

func parseTargetOS(s string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "windows", "win":
		return "windows", nil
	case "unix", "linux", "":
		return "unix", nil
	default:
		return "", fmt.Errorf("invalid target_os %q: must be 'windows' or 'unix'", s)
	}
}

func VisitedAny(visited map[string]bool, names ...string) bool {
	if visited == nil {
		return true
	}
	for _, n := range names {
		if visited[n] {
			return true
		}
	}
	return false
}

// loadTrace captures config load steps for DebugLogSummary (after logger.Init).
type loadTrace struct {
	entry        string
	iniPath      string
	iniKeys      []string
	cliOverrides []string
	positional   []string
	mergeNotes   []string
}

var lastLoadTrace loadTrace

func resetLoadTrace(entry string) {
	lastLoadTrace = loadTrace{entry: entry}
}

func recordINILoaded(path string, keys []string) {
	lastLoadTrace.iniPath = path
	lastLoadTrace.iniKeys = append([]string(nil), keys...)
}

func recordNoINI() {
	lastLoadTrace.iniPath = ""
	lastLoadTrace.iniKeys = nil
}

func recordCLIOverrides(visited map[string]bool) {
	if visited == nil {
		return
	}
	names := make([]string, 0, len(visited))
	for name := range visited {
		names = append(names, name)
	}
	lastLoadTrace.cliOverrides = names
}

func recordPositional(args []string, intervalSet, countSet bool) {
	lastLoadTrace.positional = append([]string(nil), args...)
	if intervalSet {
		lastLoadTrace.mergeNotes = append(lastLoadTrace.mergeNotes, "positional: interval overridden")
	}
	if countSet {
		lastLoadTrace.mergeNotes = append(lastLoadTrace.mergeNotes, "positional: count overridden")
	}
}

func recordMergeNote(note string) {
	if strings.TrimSpace(note) != "" {
		lastLoadTrace.mergeNotes = append(lastLoadTrace.mergeNotes, note)
	}
}

// DebugLogSummary writes INI/CLI merge details to ytop_debug.log.
// Call once after logger.Init when cfg.DebugMode is true.
func DebugLogSummary(cfg *Config) {
	if cfg == nil || !cfg.DebugMode {
		return
	}

	logger.DebugSection("config-load")
	logger.DebugKeyVal("entry", lastLoadTrace.entry)
	if lastLoadTrace.iniPath != "" {
		logger.DebugKeyVal("ini_file", lastLoadTrace.iniPath)
		logger.Debug("  ini_keys (%d): %s\n", len(lastLoadTrace.iniKeys), strings.Join(lastLoadTrace.iniKeys, ", "))
	} else {
		logger.DebugKeyVal("ini_file", "(none)")
	}

	if len(lastLoadTrace.cliOverrides) > 0 {
		logger.Debug("  cli_flags (%d): %s\n", len(lastLoadTrace.cliOverrides), strings.Join(lastLoadTrace.cliOverrides, ", "))
	} else {
		logger.Debug("  cli_flags: (none explicit; defaults/ini kept)\n")
	}

	if len(lastLoadTrace.positional) > 0 {
		logger.Debug("  positional_args: %s\n", strings.Join(lastLoadTrace.positional, " "))
	}
	for _, note := range lastLoadTrace.mergeNotes {
		logger.Debug("  merge: %s\n", note)
	}

	logger.DebugSection("config-final")
	logConfigField("ConnectionMode", cfg.ConnectionMode)
	logConfigField("DBType", cfg.DBType)
	logConfigField("DBVersion", cfg.DBVersion)
	logConfigField("YasqlPath", cfg.YasqlPath)
	logConfigField("ConnectString", cfg.ConnectString)
	logConfigField("LoginCmd", cfg.LoginCmd)
	logConfigField("SSHHost", cfg.SSHHost)
	logger.Debug("  SSHPort=%d SSHUser=%s\n", cfg.SSHPort, cfg.SSHUser)
	if cfg.SSHPassword != "" {
		logger.Debug("  SSHPassword=(set)\n")
	}
	if cfg.SSHKeyFile != "" {
		logConfigField("SSHKeyFile", cfg.SSHKeyFile)
	}
	logConfigField("SourceCmd", cfg.SourceCmd)
	logConfigField("TargetOS", cfg.TargetOS)
	logger.Debug("  Interval=%d Count=%d InstanceID=%d\n", cfg.Interval, cfg.Count, cfg.InstanceID)
	logger.Debug("  SessionTopN=%d SessionSortBy=%q SessionDetailTopN=%d EventTopN=%d\n",
		cfg.SessionTopN, cfg.SessionSortBy, cfg.SessionDetailTopN, cfg.EventTopN)
	logger.Debug("  DebugMode=%v MetricMode=%v EnterCLI=%v JdbcEnter=%v ColorEnabled=%v ShowTimestamp=%v\n",
		cfg.DebugMode, cfg.MetricMode, cfg.EnterCLI, cfg.JdbcEnter, cfg.ColorEnabled, cfg.ShowTimestamp)
	if cfg.ExecuteScript != "" {
		logConfigField("ExecuteScript", cfg.ExecuteScript)
	}
	if cfg.ExecuteSQL != "" {
		logConfigField("ExecuteSQL", cfg.ExecuteSQL)
	}
	if cfg.ReadScript != "" {
		logConfigField("ReadScript", cfg.ReadScript)
	}
	if cfg.CopyScript != "" {
		logConfigField("CopyScript", cfg.CopyScript)
	}
	if cfg.FindScriptSet {
		logConfigField("FindScript", cfg.FindScript)
	}
	if cfg.OutputFile != "" {
		logConfigField("OutputFile", cfg.OutputFile)
	}
	if cfg.CC != "" && cfg.CC != "gcc" {
		logConfigField("CC", cfg.CC)
	}
	if cfg.CFLAGS != "" {
		logConfigField("CFLAGS", cfg.CFLAGS)
	}
	if cfg.LDFLAGS != "" {
		logConfigField("LDFLAGS", cfg.LDFLAGS)
	}
	if cfg.Python != "" {
		logConfigField("Python", cfg.Python)
	} else {
		logger.DebugKeyVal("Python", "(auto-detect)")
	}
	logger.Debug("  ini_sources: interval=%v count=%v connection_mode=%v session_top=%v\n",
		cfg.iniIntervalSet, cfg.iniCountSet, cfg.iniConnectionModeSet, cfg.iniSessionTopSet)
}

func logConfigField(key, val string) {
	if val == "" {
		return
	}
	logger.DebugKeyVal(key, val)
}

// DebugLogSummaryf is a convenience wrapper with a custom entry label.
func DebugLogSummaryf(cfg *Config, entry string) {
	if entry != "" {
		lastLoadTrace.entry = entry
	}
	DebugLogSummary(cfg)
}

// stripDebugFlagsFromArgs removes -D/--debug from positional arguments.
// Standard Go flag parsing stops at the first non-flag argument, so a trailing
// "-D" after e.g. "ytop ... 3 -D" would otherwise be ignored; stripping here enables debug anyway.
func stripDebugFlagsFromArgs(args []string, cfg *Config) []string {
	var out []string
	for _, a := range args {
		if a == "-D" || a == "--debug" {
			cfg.DebugMode = true
			continue
		}
		out = append(out, a)
	}
	return out
}

// Validate checks if the configuration is valid
// fillJdbcEnterCLI 仅从 CLI visited flag 写入 Jdbc* 快照 (不用 ini 的 SSH*).
func fillJdbcEnterCLI(cfg *Config, visited map[string]bool,
	sshHost, sshHostShort *string, port, portShort *int,
	sshUser, sshUserShort, sshPassword, sshPasswordShort *string) {
	if VisitedAny(visited, "ssh-host") {
		cfg.JdbcHost = *sshHost
	}
	if VisitedAny(visited, "t") {
		cfg.JdbcHost = *sshHostShort
	}
	if VisitedAny(visited, "port") {
		cfg.JdbcPort = *port
		cfg.JdbcPortSet = true
	}
	if VisitedAny(visited, "P") {
		cfg.JdbcPort = *portShort
		cfg.JdbcPortSet = true
	}
	if VisitedAny(visited, "ssh-user") {
		cfg.JdbcUser = *sshUser
	}
	if VisitedAny(visited, "u") {
		cfg.JdbcUser = *sshUserShort
	}
	if VisitedAny(visited, "ssh-password") {
		cfg.JdbcPassword = *sshPassword
		cfg.JdbcPasswordSet = true
	}
	if VisitedAny(visited, "p") {
		cfg.JdbcPassword = *sshPasswordShort
		cfg.JdbcPasswordSet = true
	}
}

func (c *Config) Validate() error {
	if c.ConnectionMode != "local" && c.ConnectionMode != "ssh" {
		return fmt.Errorf("connection_mode must be 'local' or 'ssh'")
	}

	if c.JdbcEnter {
		if c.JdbcHost == "" || !c.JdbcPortSet || c.JdbcPort <= 0 ||
			c.JdbcUser == "" || !c.JdbcPasswordSet {
			return fmt.Errorf("-E requires -t <db-host>, -P <db-port>, -u <user>, and -p <password> (-J optional if driver embedded)")
		}
		// 显式 -J 路径在此校验; 未传则运行时 ResolveJdbcDriverJar (embed / JDBC_JAR)
		if strings.TrimSpace(c.JdbcJar) != "" {
			st, err := os.Stat(c.JdbcJar)
			if err != nil || st.IsDir() {
				return fmt.Errorf("JDBC driver jar not found: %s", c.JdbcJar)
			}
		}
		if c.DbName == "" {
			c.DbName = "yasdb"
		}
	}

	// YashanDB is not supported on Windows (local or explicit target-os=windows).
	// SSH auto-detection is done later in Connect(); block only the explicit case here.
	// -E 本机 JDBC 不依赖本机 yasql, 跳过 YashanDB/Windows 本地限制.
	if c.DBType == "yashandb" && !c.JdbcEnter {
		if c.ConnectionMode == "local" && isLocalWindows() {
			return fmt.Errorf(
				"YashanDB is not supported on Windows.\n" +
					"  Run ytop on a Linux/Unix host, or use SSH mode (-t <linux_host>) to connect remotely.")
		}
		if c.TargetOS == "windows" {
			return fmt.Errorf(
				"YashanDB is not supported on a Windows target (--target-os windows).\n" +
					"  Use SSH to a Linux/Unix host instead.")
		}
	}

	if c.ConnectionMode == "ssh" && !c.JdbcEnter {
		if c.SSHHost == "" {
			return fmt.Errorf("ssh_host is required when connection_mode is 'ssh'")
		}

		// Check if ssh command exists
		if err := checkSSHCommand(); err != nil {
			return err
		}

		// Set default SSH user based on DB type if not specified
		if c.SSHUser == "" {
			switch c.DBType {
			case "oracle":
				c.SSHUser = "oracle"
			case "dameng":
				c.SSHUser = "dmdba"
			case "mysql":
				c.SSHUser = "root"
			case "postgresql":
				c.SSHUser = "postgres"
			case "mssql":
				c.SSHUser = "Administrator"
			default:
				c.SSHUser = "yashan"
			}
		}
		// If no password or key file specified, try default SSH key
		if c.SSHPassword == "" && c.SSHKeyFile == "" {
			homeDir, err := os.UserHomeDir()
			if err == nil {
				defaultKeyFile := homeDir + "/.ssh/id_rsa"
				if _, err := os.Stat(defaultKeyFile); err == nil {
					c.SSHKeyFile = defaultKeyFile
				} else {
					return fmt.Errorf("either ssh_password or ssh_key_file is required for SSH connection (default key ~/.ssh/id_rsa not found)")
				}
			} else {
				return fmt.Errorf("either ssh_password or ssh_key_file is required for SSH connection")
			}
		}
	}

	// In direct execution mode, interval can be 0
	// In interactive monitoring mode, interval must be at least 1
	isDirectMode := c.ExecuteScript != "" || c.ExecuteSQL != "" || c.ReadScript != "" ||
		c.CopyScript != "" || c.FindScriptSet || c.EnterCLI || c.JdbcEnter

	if !isDirectMode && c.Interval < 1 {
		return fmt.Errorf("interval must be at least 1 second")
	}

	if c.Count < 0 {
		return fmt.Errorf("count cannot be negative")
	}

	return nil
}

// firstCLIToken 取 -f 等参数的首 token (脚本名).
func firstCLIToken(s string) string {
	fields := strings.Fields(strings.TrimSpace(s))
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// checkSSHCommand checks if ssh command is available
func checkSSHCommand() error {
	_, err := exec.LookPath("ssh")
	if err != nil {
		return fmt.Errorf("ssh command not found in PATH. Please install OpenSSH client to use SSH connection mode")
	}
	return nil
}

// isLocalWindows returns true when the current process is running on Windows.
func isLocalWindows() bool {
	return strings.EqualFold(os.Getenv("GOOS"), "windows") ||
		// Use runtime constant via the platform package would create an import cycle,
		// so check env/os markers instead.
		(os.PathSeparator == '\\')
}

// PrintUsage prints brief usage with mode overview
func PrintUsage() {
	fmt.Println("ytop - Real-time database performance monitor")
	fmt.Println()
	fmt.Println("Modes:")
	fmt.Println("  ytop [options] [interval] [count]             Monitor (default)")
	fmt.Println("  ytop -f <script>|-q <sql> [options] [int] [n]   Script / SQL execution")
	fmt.Println("  ytop stat|sesstat [options] [interval] [count] Session statistics")
	fmt.Println("  ytop event|sesevent [options] [interval] [count] Session events")
	fmt.Println("  ytop ssh [options]                          Configure SSH passwordless login")
	fmt.Println()
	fmt.Println("Use \"ytop <mode> --help\" for details:")
	fmt.Println("  ytop monitor --help      Monitor mode help")
	fmt.Println("  ytop script --help       Script execution help")
	fmt.Println("  ytop stat --help         Session statistics help")
	fmt.Println("  ytop event --help        Session events help")
	fmt.Println("  ytop ssh --help          SSH passwordless login help")
	fmt.Println()
	fmt.Println("Connection:")
	fmt.Println("  -C, --connect <str>       Connection string (default: / as sysdba)")
	fmt.Println("  -t, --host <host>         SSH host (enables SSH mode)")
	fmt.Println("  -P, --port <port>         SSH port (default: 22)")
	fmt.Println("  -u, --user <user>         SSH user")
	fmt.Println("  -p, --password <pass>     SSH password")
	fmt.Println("  -k, --key <file>          SSH private key file")
	fmt.Println("  -s, --source <path>       Env file to source before DB CLI")
	fmt.Println("  -c, --config <file>       Path to config file (required to load ini)")
	fmt.Println()
	fmt.Println("Database:")
	fmt.Println("  -d, --db-type <type>      DB type: yas(han)(default), o(ra), d(m), m(y), p(g), s(ms)")
	fmt.Println("  -V, --db-version <ver>    DB version for script resolution (default: auto via CLI -v)")
	fmt.Println("  --login-cmd <cmd>         Custom DB login command")
	fmt.Println()
	fmt.Println("Output:")
	fmt.Println("  -o, --output <file>       Append output to file")
	fmt.Println("  -I, --inst <id>           Instance ID (0=all, default: 0)")
	fmt.Println("  -D, --debug               Enable debug mode")
	fmt.Println("  -v, --version             Show version")
}

// PrintMonitorUsage prints detailed help for monitor mode
func PrintMonitorUsage() {
	fmt.Println("ytop monitor - Real-time interactive monitoring (default mode)")
	fmt.Println()
	fmt.Println("Usage:  ytop [options] [interval] [count]")
	fmt.Println()
	fmt.Println("Displays live database metrics in terminal:")
	fmt.Println("  - System statistics (v$sysstat) per-second rates")
	fmt.Println("  - TOP 5 wait events (v$system_event)")
	fmt.Println("  - TOP N sessions by configurable column")
	fmt.Println("  - Active session details")
	fmt.Println()
	fmt.Println("Connection:")
	fmt.Println("  -C, --connect <str>       Connection string (default: / as sysdba)")
	fmt.Println("  -t, --host <host>         SSH host (enables SSH mode)")
	fmt.Println("  -P, --port <port>         SSH port (default: 22)")
	fmt.Println("  -u, --user <user>         SSH user")
	fmt.Println("  -p, --password <pass>     SSH password")
	fmt.Println("  -k, --key <file>          SSH private key file")
	fmt.Println("  -s, --source <path>       Env file to source before DB CLI")
	fmt.Println("  -c, --config <file>       Path to config file (required to load ini)")
	fmt.Println()
	fmt.Println("Database:")
	fmt.Println("  -d, --db-type <type>      DB type: yas(han)(default), o(ra), d(m), m(y), p(g), s(ms)")
	fmt.Println("  -V, --db-version <ver>    DB version for script resolution (default: auto via CLI -v)")
	fmt.Println("  --login-cmd <cmd>         Custom DB login command")
	fmt.Println()
	fmt.Println("Output:")
	fmt.Println("  -o, --output <file>       Append output to file")
	fmt.Println("  --session-top <num>       TOP N sessions (default: 5)")
	fmt.Println("  --session-sort <col>      Session sort column (default: DB TIME)")
	fmt.Println("  --session-detail-top <n>  Active sessions to show (default: 10)")
	fmt.Println("  -I, --inst <id>           Instance ID (0=all, default: 0)")
	fmt.Println("  -D, --debug               Enable debug mode")
	fmt.Println()
	fmt.Println("Positional:  [interval] [count]  default: 5s, unlimited")
	fmt.Println()
	fmt.Println("Interactive Keys:")
	fmt.Println("  ↑/↓          Navigate sessions        a/A    Ad-hoc SQL")
	fmt.Println("  p/P          View SQL plan            s/S    Execute script/cmd")
	fmt.Println("  r/R          View script content      f/F    Search scripts")
	fmt.Println("  c/C          Copy script              h/H    Show help")
	fmt.Println("  q/Q/ESC      Quit")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  ytop                                        # Default: 5s interval, unlimited")
	fmt.Println("  ytop 1                                      # 1s interval, unlimited")
	fmt.Println("  ytop 1 20                                   # 1s interval, 20 iterations")
	fmt.Println("  ytop -C \"/ as sysdba\"                       # Local connection")
	fmt.Println("  ytop -t 10.10.10.130 -u yashan -p oracle -s ~/.bashrc")
	fmt.Println("  ytop -c config.ini                          # Use config file")
	fmt.Println("  ytop --session-top 20 --session-sort \"CPU TIME\"")
}

// PrintScriptUsage prints detailed help for script execution mode
func PrintScriptUsage() {
	fmt.Println("ytop script - Execute scripts and SQL queries")
	fmt.Println()
	fmt.Println("Usage:  ytop -f <script>|-q <sql> [options] [interval] [count]")
	fmt.Println()
	fmt.Println("Execution:")
	fmt.Println("  -f <script>               Execute script (SQL, OS, C, or Python)")
	fmt.Println("                             SQL: embedded sql/<dbtype>/ or path ending .sql")
	fmt.Println("                             OS: embedded os/ or shell command")
	fmt.Println("                             C/Py: embedded os/ (.c compile, .py interpret)")
	fmt.Println("                             Full path: /path/to/file or ./file")
	fmt.Println("                             With args: -f \"memtest.c -i 1 -t 2\"")
	fmt.Println("  -q <sql>                  Execute SQL query directly")
	fmt.Println("  -r <script>               View script content")
	fmt.Println("  --copy <script> [dest]    Copy script to destination (default: /tmp)")
	fmt.Println("  -S <pattern>              Search scripts by regex (empty pattern lists all)")
	fmt.Println("  -m, --metric              Delta/per-second mode (with -f)")
	fmt.Println()
	fmt.Println("Connection:")
	fmt.Println("  -C, --connect <str>       Connection string (default: / as sysdba)")
	fmt.Println("  -t, --host <host>         SSH host (enables SSH mode)")
	fmt.Println("  -P, --port <port>         SSH port (default: 22)")
	fmt.Println("  -u, --user <user>         SSH user")
	fmt.Println("  -p, --password <pass>     SSH password")
	fmt.Println("  -k, --key <file>          SSH private key file")
	fmt.Println("  -s, --source <path>       Env file to source before DB CLI")
	fmt.Println("  -c, --config <file>       Path to config file (required to load ini)")
	fmt.Println()
	fmt.Println("Database:")
	fmt.Println("  -d, --db-type <type>      DB type: yas(han)(default), o(ra), d(m), m(y), p(g), s(ms)")
	fmt.Println("  -V, --db-version <ver>    DB version for script resolution (default: auto via CLI -v)")
	fmt.Println("  --login-cmd <cmd>         Custom DB login command")
	fmt.Println("  --cc <compiler>           C compiler for -f *.c (default: gcc)")
	fmt.Println("  --cflags <flags>          C compile flags for -f *.c")
	fmt.Println("  --ldflags <flags>         C link flags for -f *.c (e.g. -lm)")
	fmt.Println("  --python <path>           Python for -f *.py (default: auto-detect)")
	fmt.Println()
	fmt.Println("Output:")
	fmt.Println("  -o, --output <file>       Append output to file")
	fmt.Println("  -I, --inst <id>           Instance ID (0=all, default: 0)")
	fmt.Println("  -D, --debug               Enable debug mode")
	fmt.Println()
	fmt.Println("Positional:  [interval] [count]")
	fmt.Println("  Default without interval: execute once")
	fmt.Println("  With interval: repeat every N seconds, unlimited or count times")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  ytop -f we.sql                              # Execute SQL script once")
	fmt.Println("  ytop -f we.sql 5 10                         # Every 5s, 10 times")
	fmt.Println("  ytop -f gv_vm.sql -m 1 10                   # Metric mode, 1s, 10 times")
	fmt.Println("  ytop -q \"select * from v$version\"            # Execute SQL query once")
	fmt.Println("  ytop -q \"select count(*) from v$session\" 2 5 # Query every 2s, 5 times")
	fmt.Println("  ytop -t 10.10.10.130 -f iostat.sh           # Execute OS script on remote")
	fmt.Println("  ytop -f \"hello.c -i 1 -t 2\"               # Compile and run C on target")
	fmt.Println("  ytop -f \"hello.py --verbose\"                # Run Python script on target")
	fmt.Println("  ytop --ldflags \"-lm\" -f memtest.c           # C with link flags")
	fmt.Println("  ytop -r we.sql                              # View script content")
	fmt.Println("  ytop --copy 'we.sql /tmp'                   # Copy script")
	fmt.Println("  ytop -S 'awr'                               # Search scripts")
	fmt.Println("  ytop -S                                     # List all scripts (same as -S '.*')")
	fmt.Println("  ytop -d o --login-cmd 'sqlplus / as sysdba' -f we.sql")
	fmt.Println("  ytop -d m --login-cmd 'mysql -uroot -p\"pass\" mydb' -f we.sql")
}

// PrintSesstatUsage prints detailed help for sesstat subcommand
func PrintSesstatUsage() {
	fmt.Println("ytop sesstat - Query session statistics (v$sesstat)")
	fmt.Println()
	fmt.Println("Usage:  ytop stat [options] [interval] [count]")
	fmt.Println()
	fmt.Println("Stat Options:")
	fmt.Println("  -S, --sid <sids>          Session ID filter (comma-separated, e.g. 40,50,90)")
	fmt.Println("  -n, --stat <names>        Stat name filter (comma-separated, supports % wildcard)")
	fmt.Println()
	fmt.Println("Connection:")
	fmt.Println("  -C, --connect <str>       Connection string (default: / as sysdba)")
	fmt.Println("  -t, --host <host>         SSH host (enables SSH mode)")
	fmt.Println("  -P, --port <port>         SSH port (default: 22)")
	fmt.Println("  -u, --user <user>         SSH user")
	fmt.Println("  -p, --password <pass>     SSH password")
	fmt.Println("  -k, --key <file>          SSH private key file")
	fmt.Println("  -s, --source <path>       Env file to source before DB CLI")
	fmt.Println("  -c, --config <file>       Path to config file")
	fmt.Println()
	fmt.Println("Output:")
	fmt.Println("  --session-top <num>       TOP N results (default: 5)")
	fmt.Println("  --count <num>             Number of samples (default: 2)")
	fmt.Println("  -I, --inst <id>           Instance ID (0=all, default: 0)")
	fmt.Println("  -D, --debug               Enable debug mode")
	fmt.Println()
	fmt.Println("Positional:  [interval] [count]  default: 1s, 2")
	fmt.Println()
	fmt.Println("Behavior:")
	fmt.Println("  Without --sid: TOP N sessions by total stat value")
	fmt.Println("  With --sid:    TOP N stats for specified sessions")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  ytop stat -c config.ini -t 10.10.10.130")
	fmt.Println("  ytop stat -t 10.10.10.130 -u yashan -p oracle -s ~/.bashrc")
	fmt.Println("  ytop stat -S 40,50 -n \"CPU%,parse%\"")
	fmt.Println("  ytop stat -I 1 --session-top 10")
}

// PrintSeseventUsage prints detailed help for sesevent subcommand
func PrintSeseventUsage() {
	fmt.Println("ytop sesevent - Query session events (v$session_event)")
	fmt.Println()
	fmt.Println("Usage:  ytop event [options] [interval] [count]")
	fmt.Println()
	fmt.Println("Event Options:")
	fmt.Println("  -S, --sid <sids>          Session ID filter (comma-separated, e.g. 40,50,90)")
	fmt.Println("  -e, --event <names>       Event name filter (comma-separated, supports % wildcard)")
	fmt.Println()
	fmt.Println("Connection:")
	fmt.Println("  -C, --connect <str>       Connection string (default: / as sysdba)")
	fmt.Println("  -t, --host <host>         SSH host (enables SSH mode)")
	fmt.Println("  -P, --port <port>         SSH port (default: 22)")
	fmt.Println("  -u, --user <user>         SSH user")
	fmt.Println("  -p, --password <pass>     SSH password")
	fmt.Println("  -k, --key <file>          SSH private key file")
	fmt.Println("  -s, --source <path>       Env file to source before DB CLI")
	fmt.Println("  -c, --config <file>       Path to config file")
	fmt.Println()
	fmt.Println("Output:")
	fmt.Println("  --session-top <num>       TOP N results (default: 5)")
	fmt.Println("  --count <num>             Number of samples (default: 2)")
	fmt.Println("  -I, --inst <id>           Instance ID (0=all, default: 0)")
	fmt.Println("  -D, --debug               Enable debug mode")
	fmt.Println()
	fmt.Println("Positional:  [interval] [count]  default: 1s, 2")
	fmt.Println()
	fmt.Println("Behavior:")
	fmt.Println("  Without --sid: TOP N sessions by total wait time")
	fmt.Println("  With --sid:    TOP N events for specified sessions")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  ytop event -t 10.10.10.130 -u yashan -p oracle -s ~/.bashrc")
	fmt.Println("  ytop event -S 40,50 -e \"db%,log%\"")
	fmt.Println("  ytop event -I 1 --session-top 10")
}

// PrintSSHUsage prints detailed help for the ssh subcommand
func PrintSSHUsage() {
	fmt.Println("ytop ssh - Configure SSH passwordless login")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  ytop ssh -t <host> -u <user> -p <password> [options]       Setup")
	fmt.Println("  ytop ssh --delete -t <host> -u <user> [-k <key>]           Remove")
	fmt.Println()
	fmt.Println("Setup:  automate SSH key-based authentication (equivalent to ssh-copy-id).")
	fmt.Println("Delete: remove public key from remote host (uses key auth, no password needed).")
	fmt.Println()
	fmt.Println("Required:")
	fmt.Println("  -t, --host <host>         Target SSH host")
	fmt.Println("  -u, --user <user>         SSH username")
	fmt.Println("  -p, --password <pass>     SSH password (required for setup only)")
	fmt.Println()
	fmt.Println("Options:")
	fmt.Println("  -c, --config <file>       Path to config file")
	fmt.Println("  -P, --port <port>         SSH port (default: 22)")
	fmt.Println("  -k, --key <file>          Local private key file (default: ~/.ssh/id_rsa)")
	fmt.Println("  --delete                  Remove public key from remote host")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  ytop ssh -t 10.10.10.130 -u yashan -p 'mypassword'")
	fmt.Println("  ytop ssh -t 10.10.10.130 -u yashan -p 'pass' -P 2222")
	fmt.Println("  ytop ssh --delete -t 10.10.10.130 -u yashan")
	fmt.Println("  ytop ssh --delete -t 10.10.10.130 -u yashan -k ~/.ssh/id_rsa")
}
