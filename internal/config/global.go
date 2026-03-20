package config

import "flag"

// GlobalFlags holds global command line flags
type GlobalFlags struct {
	// Connection flags
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

	// Common flags
	Interval int
	Count    int
	TopN     int

	// Other flags
	OutputFile string
	InstanceID int
	Debug      bool
}

// ParseGlobalFlags parses global flags from command line
func ParseGlobalFlags(fs *flag.FlagSet) *GlobalFlags {
	gf := &GlobalFlags{}

	// Connection flags
	fs.StringVar(&gf.ConfigFile, "config", "", "Path to config file")

	fs.StringVar(&gf.YasqlPath, "yasql", "yasql", "Path to yasql executable")

	fs.StringVar(&gf.ConnectString, "connect", "/ as sysdba", "Connection string")
	fs.StringVar(&gf.ConnectString, "C", "/ as sysdba", "Connection string (short)")

	fs.StringVar(&gf.SSHHost, "host", "", "SSH host")
	fs.StringVar(&gf.SSHHost, "h", "", "SSH host (short)")

	fs.IntVar(&gf.SSHPort, "port", 0, "SSH port")
	fs.IntVar(&gf.SSHPort, "P", 0, "SSH port (short)")

	fs.StringVar(&gf.SSHUser, "user", "", "SSH user")
	fs.StringVar(&gf.SSHUser, "u", "", "SSH user (short)")

	fs.StringVar(&gf.SSHPassword, "password", "", "SSH password")
	fs.StringVar(&gf.SSHPassword, "p", "", "SSH password (short)")

	fs.StringVar(&gf.SSHKeyFile, "key", "", "SSH private key file")
	fs.StringVar(&gf.SSHKeyFile, "k", "", "SSH private key file (short)")

	fs.StringVar(&gf.SourceCmd, "source", "", "Source command to run before yasql")
	fs.StringVar(&gf.SourceCmd, "s", "", "Source command (short)")

	// Common flags
	fs.IntVar(&gf.Interval, "interval", 5, "Interval in seconds")
	fs.IntVar(&gf.Interval, "i", 5, "Interval (short)")

	fs.IntVar(&gf.Count, "count", 5, "Number of result outputs (excludes baseline)")
	fs.IntVar(&gf.Count, "c", 5, "Number of result outputs (short)")

	fs.IntVar(&gf.TopN, "top", 5, "Number of top results to show")
	fs.IntVar(&gf.TopN, "t", 5, "Number of top results (short)")

	// Other flags
	fs.StringVar(&gf.OutputFile, "output", "", "Output file path")
	fs.StringVar(&gf.OutputFile, "o", "", "Output file (short)")

	fs.IntVar(&gf.InstanceID, "inst", 0, "Instance ID (0 = all instances)")
	fs.IntVar(&gf.InstanceID, "I", 0, "Instance ID (short)")

	fs.BoolVar(&gf.Debug, "debug", false, "Enable debug mode")
	fs.BoolVar(&gf.Debug, "d", false, "Enable debug mode (short)")

	return gf
}

// ApplyToConfig applies global flags to config
func (gf *GlobalFlags) ApplyToConfig(cfg *Config) {
	// Auto-detect connection mode based on SSH host
	if gf.SSHHost != "" {
		cfg.ConnectionMode = "ssh"
	} else {
		cfg.ConnectionMode = "local"
	}

	if gf.YasqlPath != "" {
		cfg.YasqlPath = gf.YasqlPath
	}
	if gf.ConnectString != "" {
		cfg.ConnectString = gf.ConnectString
	}
	if gf.SSHHost != "" {
		cfg.SSHHost = gf.SSHHost
	}
	if gf.SSHPort != 0 {  // Changed from > 0 to != 0 to handle default value properly
		cfg.SSHPort = gf.SSHPort
	}
	if gf.SSHUser != "" {
		cfg.SSHUser = gf.SSHUser
	}
	if gf.SSHPassword != "" {
		cfg.SSHPassword = gf.SSHPassword
	}
	if gf.SSHKeyFile != "" {
		cfg.SSHKeyFile = gf.SSHKeyFile
	}
	if gf.SourceCmd != "" {
		cfg.SourceCmd = gf.SourceCmd
	}
	if gf.Interval > 0 {
		cfg.Interval = gf.Interval
	}
	if gf.Count >= 0 {
		cfg.Count = gf.Count
	}
	if gf.OutputFile != "" {
		cfg.OutputFile = gf.OutputFile
	}
	if gf.InstanceID >= 0 {
		cfg.InstanceID = gf.InstanceID
	}
	if gf.Debug {
		cfg.DebugMode = gf.Debug
	}
}
