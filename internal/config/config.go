package config

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

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

	// Display settings
	Interval           int
	Count              int
	OutputFile         string
	SessionTopN        int
	SessionSortBy      string
	SessionDetailTopN  int
	ShowTimestamp      bool
	ColorEnabled       bool
	InstanceID         int // 0 = all instances, 1,2,... = specific instance

	// Metric settings
	SysStatMetrics []string
	EventTopN      int

	// Advanced settings
	QueryTimeout   int
	SSHTimeout     int
	ReuseSSH       bool
	DebugMode      bool

	// Direct execution mode (non-interactive)
	ExecuteScript  string // -f: script file to execute
	ExecuteSQL     string // -q: SQL query to execute
	ReadScript     string // -r: read/view script content
	CopyScript     string // -c: copy script (format: "script dest")
	FindScript     string // --find: find/search scripts
}

// DefaultConfig returns a config with default values
func DefaultConfig() *Config {
	return &Config{
		ConnectionMode:    "local", // Default to local mode
		YasqlPath:         "yasql",
		ConnectString:     "/ as sysdba",
		SSHPort:           22,
		Interval:          5,
		Count:             5,
		SessionTopN:       10,
		SessionSortBy:     "DB TIME",
		SessionDetailTopN: 10,
		ShowTimestamp:     true,
		ColorEnabled:      true,
		InstanceID:        0, // 0 = all instances
		SysStatMetrics: []string{
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
		},
		EventTopN:    5,
		QueryTimeout: 30,
		SSHTimeout:   10,
		ReuseSSH:     true,
		DebugMode:    false,
	}
}

// LoadConfig loads configuration from file and command line
func LoadConfig() (*Config, error) {
	cfg := DefaultConfig()

	// Customize flag error handling to show our custom usage
	flag.Usage = func() {
		PrintUsage()
	}

	// Define command line flags
	configFile := flag.String("config", "", "Path to config file")
	connectionMode := flag.String("mode", "", "Connection mode: local or ssh")
	yasqlPath := flag.String("yasql", "", "Path to yasql executable")
	connectString := flag.String("connect", "", "Connection string")
	sshHost := flag.String("ssh-host", "", "SSH host")
	sshHostShort := flag.String("h", "", "SSH host (short)")
	sshPort := flag.Int("ssh-port", 0, "SSH port")
	sshUser := flag.String("ssh-user", "", "SSH user")
	sshUserShort := flag.String("u", "", "SSH user (short)")
	sshPassword := flag.String("ssh-password", "", "SSH password")
	sshPasswordShort := flag.String("p", "", "SSH password (short)")
	sshKeyFile := flag.String("ssh-key", "", "SSH private key file")
	sshKeyFileShort := flag.String("k", "", "SSH private key file (short)")
	sourceCmd := flag.String("source", "", "Source command to run before yasql")
	sourceCmdShort := flag.String("s", "", "Source command (short)")
	interval := flag.Int("i", 0, "Refresh interval in seconds")
	count := flag.Int("c", 0, "Number of iterations (0 = infinite)")
	outputFile := flag.String("o", "", "Output file path")
	sessionTopN := flag.Int("session-top", 0, "Number of sessions to show in TOP N")
	sessionSortBy := flag.String("session-sort", "", "Session sort column")
	sessionDetailTopN := flag.Int("session-detail-top", 0, "Number of active sessions to show")
	instanceID := flag.Int("inst-id", 0, "Instance ID (0 = all instances, 1,2,... = specific instance)")
	noColor := flag.Bool("no-color", false, "Disable color output")
	noTimestamp := flag.Bool("no-timestamp", false, "Hide timestamp")
	debug := flag.Bool("debug", false, "Enable debug mode")
	debugShort := flag.Bool("d", false, "Enable debug mode (short)")
	executeScript := flag.String("f", "", "Execute script file directly (non-interactive mode)")
	executeSQL := flag.String("q", "", "Execute SQL query directly (non-interactive mode)")
	readScript := flag.String("r", "", "Read/view script content (non-interactive mode)")
	copyScript := flag.String("copy", "", "Copy script to destination (format: 'script dest', non-interactive mode)")
	findScript := flag.String("find", "", "Find/search scripts by pattern (non-interactive mode)")

	flag.Parse()

	// Load from config file if specified
	if *configFile != "" {
		if err := loadFromFile(cfg, *configFile); err != nil {
			return nil, fmt.Errorf("failed to load config file: %w", err)
		}
	}

	// Override with command line flags
	if *connectionMode != "" {
		cfg.ConnectionMode = *connectionMode
	}
	if *yasqlPath != "" {
		cfg.YasqlPath = *yasqlPath
	}
	if *connectString != "" {
		cfg.ConnectString = *connectString
	}
	if *sshHost != "" {
		cfg.SSHHost = *sshHost
	}
	if *sshHostShort != "" {
		cfg.SSHHost = *sshHostShort
	}
	if *sshPort > 0 {
		cfg.SSHPort = *sshPort
	}
	if *sshUser != "" {
		cfg.SSHUser = *sshUser
	}
	if *sshUserShort != "" {
		cfg.SSHUser = *sshUserShort
	}
	if *sshPassword != "" {
		cfg.SSHPassword = *sshPassword
	}
	if *sshPasswordShort != "" {
		cfg.SSHPassword = *sshPasswordShort
	}
	if *sshKeyFile != "" {
		cfg.SSHKeyFile = *sshKeyFile
	}
	if *sshKeyFileShort != "" {
		cfg.SSHKeyFile = *sshKeyFileShort
	}
	if *sourceCmd != "" {
		cfg.SourceCmd = *sourceCmd
	}
	if *sourceCmdShort != "" {
		cfg.SourceCmd = *sourceCmdShort
	}
	if *outputFile != "" {
		cfg.OutputFile = *outputFile
	}
	if *sessionTopN > 0 {
		cfg.SessionTopN = *sessionTopN
	}
	if *sessionSortBy != "" {
		cfg.SessionSortBy = *sessionSortBy
	}
	if *sessionDetailTopN > 0 {
		cfg.SessionDetailTopN = *sessionDetailTopN
	}
	if *noColor {
		cfg.ColorEnabled = false
	}
	if *noTimestamp {
		cfg.ShowTimestamp = false
	}
	if *debug || *debugShort {
		cfg.DebugMode = true
	}
	if *instanceID >= 0 {
		cfg.InstanceID = *instanceID
	}
	if *executeScript != "" {
		cfg.ExecuteScript = *executeScript
	}
	if *executeSQL != "" {
		cfg.ExecuteSQL = *executeSQL
	}
	if *readScript != "" {
		cfg.ReadScript = *readScript
	}
	if *copyScript != "" {
		cfg.CopyScript = *copyScript
	}
	if *findScript != "" {
		cfg.FindScript = *findScript
	}

	// Auto-detect connection mode based on SSH host
	// If user explicitly set mode, use that; otherwise auto-detect
	if *connectionMode == "" {
		if cfg.SSHHost != "" {
			cfg.ConnectionMode = "ssh"
		} else {
			cfg.ConnectionMode = "local"
		}
	}

	// Handle positional arguments (interval [count])
	args := flag.Args()

	// Check if in direct execution mode
	isDirectMode := cfg.ExecuteScript != "" || cfg.ExecuteSQL != "" || cfg.ReadScript != "" ||
		cfg.CopyScript != "" || cfg.FindScript != ""

	// Handle interval: command line flag > positional arg > direct mode default (0) > config/default (5)
	intervalSpecified := false
	if *interval > 0 {
		cfg.Interval = *interval
		intervalSpecified = true
	} else if len(args) >= 1 {
		if i, err := strconv.Atoi(args[0]); err == nil && i >= 0 {
			cfg.Interval = i
			intervalSpecified = true
		}
	}

	// In direct execution mode, if interval not explicitly specified, set to 0
	if isDirectMode && !intervalSpecified {
		cfg.Interval = 0
	}

	// Handle count: command line flag > positional arg > direct mode default (1) > config/default (5)
	countSpecified := false
	if *count >= 0 {
		cfg.Count = *count
		countSpecified = true
	} else if len(args) >= 2 {
		if c, err := strconv.Atoi(args[1]); err == nil && c >= 0 {
			cfg.Count = c
			countSpecified = true
		}
	}

	// In direct execution mode, if count not explicitly specified, set to 1 (execute once)
	if isDirectMode && !countSpecified {
		cfg.Count = 1
	}

	// Validate configuration
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// loadFromFile loads configuration from INI file
func loadFromFile(cfg *Config, path string) error {
	iniFile, err := ini.Load(path)
	if err != nil {
		return err
	}

	section := iniFile.Section("")

	if section.HasKey("connection_mode") {
		cfg.ConnectionMode = section.Key("connection_mode").String()
	}
	if section.HasKey("yasql_path") {
		cfg.YasqlPath = section.Key("yasql_path").String()
	}
	if section.HasKey("connect_string") {
		cfg.ConnectString = section.Key("connect_string").String()
	}
	if section.HasKey("ssh_host") {
		cfg.SSHHost = section.Key("ssh_host").String()
	}
	if section.HasKey("ssh_port") {
		cfg.SSHPort = section.Key("ssh_port").MustInt(22)
	}
	if section.HasKey("ssh_user") {
		cfg.SSHUser = section.Key("ssh_user").String()
	}
	if section.HasKey("ssh_password") {
		cfg.SSHPassword = section.Key("ssh_password").String()
	}
	if section.HasKey("ssh_key_file") {
		cfg.SSHKeyFile = section.Key("ssh_key_file").String()
	}
	if section.HasKey("source_cmd") {
		cfg.SourceCmd = section.Key("source_cmd").String()
	}
	if section.HasKey("interval") {
		cfg.Interval = section.Key("interval").MustInt(1)
	}
	if section.HasKey("count") {
		cfg.Count = section.Key("count").MustInt(0)
	}
	if section.HasKey("output_file") {
		cfg.OutputFile = section.Key("output_file").String()
	}
	if section.HasKey("session_top_n") {
		cfg.SessionTopN = section.Key("session_top_n").MustInt(10)
	}
	if section.HasKey("session_sort_by") {
		cfg.SessionSortBy = section.Key("session_sort_by").String()
	}
	if section.HasKey("session_detail_top_n") {
		cfg.SessionDetailTopN = section.Key("session_detail_top_n").MustInt(10)
	}
	if section.HasKey("sysstat_metrics") {
		metricsStr := section.Key("sysstat_metrics").String()
		if metricsStr != "" {
			cfg.SysStatMetrics = strings.Split(metricsStr, ",")
			for i := range cfg.SysStatMetrics {
				cfg.SysStatMetrics[i] = strings.TrimSpace(cfg.SysStatMetrics[i])
			}
		}
	}
	if section.HasKey("event_top_n") {
		cfg.EventTopN = section.Key("event_top_n").MustInt(5)
	}

	return nil
}

// Validate checks if the configuration is valid
func (c *Config) Validate() error {
	if c.ConnectionMode != "local" && c.ConnectionMode != "ssh" {
		return fmt.Errorf("connection_mode must be 'local' or 'ssh'")
	}

	if c.ConnectionMode == "ssh" {
		if c.SSHHost == "" {
			return fmt.Errorf("ssh_host is required when connection_mode is 'ssh'")
		}

		// Check if ssh command exists
		if err := checkSSHCommand(); err != nil {
			return err
		}

		// Set default SSH user if not specified
		if c.SSHUser == "" {
			c.SSHUser = "yashan"
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
		c.CopyScript != "" || c.FindScript != ""

	if !isDirectMode && c.Interval < 1 {
		return fmt.Errorf("interval must be at least 1 second")
	}

	if c.Count < 0 {
		return fmt.Errorf("count cannot be negative")
	}

	return nil
}

// checkSSHCommand checks if ssh command is available
func checkSSHCommand() error {
	_, err := exec.LookPath("ssh")
	if err != nil {
		return fmt.Errorf("ssh command not found in PATH. Please install OpenSSH client to use SSH connection mode")
	}
	return nil
}

// PrintUsage prints usage information
func PrintUsage() {
	fmt.Println("ytop - Real-time performance monitoring tool for YashanDB")
	fmt.Println("\nUsage:")
	fmt.Println("  ytop [global options] [interval] [count]           # Monitor mode (default)")
	fmt.Println("  ytop -f <script> [global options] [interval] [count] # Execute script directly")
	fmt.Println("  ytop -q <sql> [global options] [interval] [count]    # Execute SQL directly")
	fmt.Println("  ytop -r <script> [global options]                    # Read script content")
	fmt.Println("  ytop --copy <script dest> [global options]           # Copy script to destination")
	fmt.Println("  ytop --find <pattern> [global options]               # Find scripts by pattern")
	fmt.Println("  ytop --plan [global options]                         # Show SQL plan")
	fmt.Println("  ytop sesstat|stat [global options] [stat options]  # Session statistics query")
	fmt.Println("  ytop sesevent|event [global options] [event options] # Session events query")
	fmt.Println("  ytop --help|help                                   # Show this help")
	fmt.Println("  ytop --version|-v|version                          # Show version")
	fmt.Println("\nGlobal Options:")
	fmt.Println("  --config <file>       Path to config file")
	fmt.Println("  --yasql <path>        Path to yasql executable (default: yasql)")
	fmt.Println("  -C, --connect <string> Connection string (default: / as sysdba)")
	fmt.Println("  -h, --host <host>     SSH host (if specified, use SSH mode; otherwise local mode)")
	fmt.Println("  --port <port>         SSH port (default: 22)")
	fmt.Println("  -u, --user <user>     SSH user")
	fmt.Println("  -p, --password <pass> SSH password")
	fmt.Println("  -k, --key <file>      SSH private key file")
	fmt.Println("  -s, --source <cmd>    Source command to run before yasql")
	fmt.Println("  -i, --interval <sec>  Interval in seconds (default: 5 for monitor, 0 for direct execution)")
	fmt.Println("  -c, --count <num>     Number of samples/iterations (default: 5 for monitor, 1 for direct execution)")
	fmt.Println("  -t, --top <num>       Number of top results to show (default: 5)")
	fmt.Println("  -o, --output <file>   Output file path")
	fmt.Println("  -I, --inst <id>       Instance ID (0 = all instances, default: 0)")
	fmt.Println("  -d, --debug           Enable debug mode")
	fmt.Println("\nDirect Execution Options:")
	fmt.Println("  -f <script>           Execute script file (SQL or OS command) without entering monitor UI")
	fmt.Println("                        Script can be: script name (e.g., we.sql) or full path")
	fmt.Println("  -q <sql>              Execute SQL query directly without entering monitor UI")
	fmt.Println("  -r <script>           Read/view script content without entering monitor UI")
	fmt.Println("  --copy <script dest>  Copy script to destination (e.g., 'we.sql /tmp')")
	fmt.Println("  --find <pattern>      Find/search scripts by pattern (supports regex)")
	fmt.Println("  --plan                Show SQL plan for current session")
	fmt.Println("\nMonitor Mode Examples:")
	fmt.Println("  ytop                                    # Default: 5 second interval, 5 iterations")
	fmt.Println("  ytop 2                                  # 2 second interval, 5 iterations")
	fmt.Println("  ytop 1 20                               # 1 second interval, 20 iterations")
	fmt.Println("  ytop --config config.ini                # Use config file")
	fmt.Println("  ytop -C \"/ as sysdba\"                   # Local connection")
	fmt.Println("  ytop -h 10.10.10.130 -u yashan -p oracle -s \"source ~/.bashrc\"")
	fmt.Println("\nDirect Execution Examples:")
	fmt.Println("  ytop -f we.sql                          # Execute we.sql once")
	fmt.Println("  ytop -f we.sql -i 5 -c 10               # Execute we.sql every 5 seconds, 10 times")
	fmt.Println("  ytop -f /path/to/script.sql             # Execute script from full path")
	fmt.Println("  ytop -q \"select * from v$version\"       # Execute SQL query once")
	fmt.Println("  ytop -q \"select count(*) from v$session\" -i 2 -c 5  # Execute query every 2 seconds, 5 times")
	fmt.Println("  ytop -h 10.10.10.130 -f iostat.sh       # Execute OS script on remote server")
	fmt.Println("  ytop -r we.sql                          # Read/view we.sql content")
	fmt.Println("  ytop --copy 'we.sql /tmp'               # Copy we.sql to /tmp")
	fmt.Println("  ytop --copy 'we.sql'                    # Copy we.sql to /tmp (default)")
	fmt.Println("  ytop -h 10.10.10.130 --copy 'we.sql /opt'  # Copy to remote server")
	fmt.Println("  ytop --find '.*'                        # List all scripts")
	fmt.Println("  ytop --find '^awr'                      # Find scripts starting with 'awr'")
	fmt.Println("  ytop --find 'session'                   # Find scripts containing 'session'")
	fmt.Println("  ytop --plan                             # Show SQL plan for current session")
	fmt.Println("\nSubcommands:")
	fmt.Println("  sesstat, stat         Query session statistics (v$sesstat)")
	fmt.Println("  sesevent, event       Query session events (v$session_event)")
	fmt.Println("\nFor subcommand help:")
	fmt.Println("  ytop stat --help")
	fmt.Println("  ytop event --help")
}

// PrintSesstatUsage prints usage information for sesstat subcommand
func PrintSesstatUsage() {
	fmt.Println("ytop sesstat - Query session statistics")
	fmt.Println("\nUsage:")
	fmt.Println("  ytop sesstat|stat [global options] [stat options]")
	fmt.Println("\nStat-Specific Options:")
	fmt.Println("  -S, --sid <sids>      Session ID filter (comma-separated, e.g., 40,50,90)")
	fmt.Println("  -n, --stat <names>    Statistic name filter (comma-separated, supports % wildcard)")
	fmt.Println("\nGlobal Options:")
	fmt.Println("  -h, --host <host>     SSH host (if specified, use SSH mode; otherwise local mode)")
	fmt.Println("  -u, --user <user>     SSH user")
	fmt.Println("  -p, --password <pass> SSH password")
	fmt.Println("  -k, --key <file>      SSH private key file")
	fmt.Println("  -s, --source <cmd>    Source command to run before yasql")
	fmt.Println("  -i, --interval <sec>  Interval in seconds (default: 1)")
	fmt.Println("  -c, --count <num>     Number of samples/iterations (default: 2)")
	fmt.Println("  -t, --top <num>       Number of top results to show (default: 5)")
	fmt.Println("  -I, --inst <id>       Instance ID (0 = all instances, default: 0)")
	fmt.Println("  -d, --debug           Enable debug mode")
	fmt.Println("\nBehavior:")
	fmt.Println("  - Without --sid: Shows TOP N sessions by total statistic value")
	fmt.Println("  - With --sid: Shows TOP N statistics for specified sessions")
	fmt.Println("  - Displays percentage contribution for all results")
	fmt.Println("\nExamples:")
	fmt.Println("  # Show top 10 sessions by all statistics")
	fmt.Println("  ytop stat -h 10.10.10.130 -u yashan -p oracle -s \"source ~/.bashrc\" -c 2 -t 10")
	fmt.Println("\n  # Show statistics for specific sessions")
	fmt.Println("  ytop stat -h 10.10.10.130 -u yashan -p oracle -S 40,50 -t 10")
	fmt.Println("\n  # Filter by statistic name pattern")
	fmt.Println("  ytop stat -h 10.10.10.130 -u yashan -p oracle -n \"CPU%,parse%\" -S 40")
	fmt.Println("\n  # Filter by instance")
	fmt.Println("  ytop stat -h 10.10.10.130 -u yashan -p oracle -I 1 -t 10")
}

// PrintSeseventUsage prints usage information for sesevent subcommand
func PrintSeseventUsage() {
	fmt.Println("ytop sesevent - Query session events")
	fmt.Println("\nUsage:")
	fmt.Println("  ytop sesevent|event [global options] [event options]")
	fmt.Println("\nEvent-Specific Options:")
	fmt.Println("  -S, --sid <sids>      Session ID filter (comma-separated, e.g., 40,50,90)")
	fmt.Println("  -e, --event <names>   Event name filter (comma-separated, supports % wildcard)")
	fmt.Println("\nGlobal Options:")
	fmt.Println("  -h, --host <host>     SSH host (if specified, use SSH mode; otherwise local mode)")
	fmt.Println("  -u, --user <user>     SSH user")
	fmt.Println("  -p, --password <pass> SSH password")
	fmt.Println("  -k, --key <file>      SSH private key file")
	fmt.Println("  -s, --source <cmd>    Source command to run before yasql")
	fmt.Println("  -i, --interval <sec>  Interval in seconds (default: 1)")
	fmt.Println("  -c, --count <num>     Number of samples/iterations (default: 2)")
	fmt.Println("  -t, --top <num>       Number of top results to show (default: 5)")
	fmt.Println("  -I, --inst <id>       Instance ID (0 = all instances, default: 0)")
	fmt.Println("  -d, --debug           Enable debug mode")
	fmt.Println("\nBehavior:")
	fmt.Println("  - Without --sid: Shows TOP N sessions by total wait time")
	fmt.Println("  - With --sid: Shows TOP N events for specified sessions")
	fmt.Println("  - Displays average wait time (ms) and percentage contribution")
	fmt.Println("\nExamples:")
	fmt.Println("  # Show top 10 sessions by wait events")
	fmt.Println("  ytop event -h 10.10.10.130 -u yashan -p oracle -s \"source ~/.bashrc\" -c 2 -t 10")
	fmt.Println("\n  # Show events for specific sessions")
	fmt.Println("  ytop event -h 10.10.10.130 -u yashan -p oracle -S 40,50 -t 10")
	fmt.Println("\n  # Filter by event name pattern")
	fmt.Println("  ytop event -h 10.10.10.130 -u yashan -p oracle -e \"db%,log%\" -S 40")
	fmt.Println("\n  # Filter by instance")
	fmt.Println("  ytop event -h 10.10.10.130 -u yashan -p oracle -I 1 -t 10")
}
