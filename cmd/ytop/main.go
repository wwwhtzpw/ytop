package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/yihan/ytop/internal/calculator"
	"github.com/yihan/ytop/internal/collector"
	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/display"
	"github.com/yihan/ytop/internal/executor"
	"github.com/yihan/ytop/internal/logger"
	"github.com/yihan/ytop/internal/metric"
	"github.com/yihan/ytop/internal/models"
	"github.com/yihan/ytop/internal/scripts"
	"github.com/yihan/ytop/internal/terminal"

	"golang.org/x/term"
)

// Global input channel for coordinated stdin reading
var globalInputChan chan byte

// Global terminal state for restoration on exit
var globalOldState *term.State

// Global stop channel for graceful goroutine shutdown
var globalStopChan chan struct{}

// restoreTerminal restores terminal state from raw mode if needed
func restoreTerminal() {
	if globalOldState != nil {
		term.Restore(int(os.Stdin.Fd()), globalOldState)
		globalOldState = nil
	}
}

// stopGoroutines signals background goroutines to exit gracefully
func stopGoroutines() {
	if globalStopChan != nil {
		select {
		case <-globalStopChan:
			// already closed
		default:
			close(globalStopChan)
		}
	}
}

// printVersion prints version information
func printVersion() {
	fmt.Printf("ytop version %s\n", Version)
	fmt.Printf("Build time: %s\n", BuildTime)
	fmt.Printf("Git commit: %s\n", GitCommit)
}

func main() {
	// Check for subcommands
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "sesstat", "stat":
			runSesstat()
			return
		case "sesevent", "event":
			runSesevent()
			return
		case "monitor":
			if len(os.Args) > 2 && (os.Args[2] == "--help" || os.Args[2] == "-h" || os.Args[2] == "help") {
				config.PrintMonitorUsage()
				return
			}
			// "monitor" without --help: run monitor mode
			runMonitor()
			return
		case "script":
			if len(os.Args) > 2 && (os.Args[2] == "--help" || os.Args[2] == "-h" || os.Args[2] == "help") {
				config.PrintScriptUsage()
				return
			}
			// "script" without --help: run monitor mode (script flags like -f will be parsed by LoadConfig)
			runMonitor()
			return
		case "ssh":
			runSSH()
			return
		case "--version", "-v", "version":
			printVersion()
			return
		case "--help", "-h", "help":
			config.PrintUsage()
			return
		}
	}

	// Default: run monitoring mode or direct execution mode
	runMonitor()
}

func runMonitor() {
	// Load configuration
	cfg, err := config.LoadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading configuration: %v\n", err)
		os.Exit(1)
	}

	// Initialize logger
	if err := logger.Init(cfg.DebugMode); err != nil {
		fmt.Fprintf(os.Stderr, "Error initializing logger: %v\n", err)
		os.Exit(1)
	}
	defer logger.Close()

	config.DebugLogSummary(cfg)

	// Set script DB type and resolve DB version when possible without connecting.
	scripts.CurrentDBType = cfg.DBType
	scripts.CurrentSQLEngine = "yasql"

	// -E: 本机 JDBC; 脚本引擎=yjdbc; 版本仅认显式 -V (不跑本机 yasql -v 自动探测)
	if cfg.JdbcEnter {
		scripts.CurrentSQLEngine = "yjdbc"
		if v := strings.TrimSpace(cfg.DBVersion); v != "" {
			scripts.CurrentDBVersion = v
		}
		code, err := executor.NewExecutor(cfg, nil).EnterJdbcShell()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			if code == 0 {
				code = 1
			}
			os.Exit(code)
		}
		os.Exit(code)
	}

	connector.InitDBVersionFromConfig(context.Background(), cfg)

	// Check if only finding scripts or reading script content (no database connection needed)
	if cfg.FindScriptSet {
		handleFindScript(cfg.FindScript)
		return
	}

	if cfg.ReadScript != "" {
		handleReadScript(cfg.ReadScript)
		return
	}

	if cfg.CopyScript != "" && cfg.ConnectionMode == "local" {
		ctx := context.Background()
		handleCopyScript(ctx, cfg, executor.NewExecutor(cfg, nil))
		return
	}

	// Check monitor mode DB type support before connecting
	isDirectMode := cfg.ExecuteScript != "" || cfg.ExecuteSQL != "" || cfg.CopyScript != "" || cfg.MetricMode || cfg.EnterCLI || cfg.JdbcEnter
	if !isDirectMode && cfg.DBType != "yashandb" {
		fmt.Fprintf(os.Stderr, "Interactive monitor mode only supports YashanDB. Support for other database types is coming soon.\n")
		os.Exit(1)
	}

	// Create connector (for database operations)
	conn, err := connector.NewConnector(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating connector: %v\n", err)
		os.Exit(1)
	}

	// Connect to database
	ctx := context.Background()
	if err := conn.Connect(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Error connecting to database: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	// Auto-detect DB version via CLI -v when --db-version is not set.
	if !cfg.EnterCLI {
		connector.InitDBVersion(ctx, cfg, conn)
	}

	if cfg.EnterCLI {
		exec := executor.NewExecutor(cfg, conn)
		code, err := exec.EnterInteractiveCLI(ctx)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			if code == 0 {
				code = 1
			}
			os.Exit(code)
		}
		os.Exit(code)
	}

	// Check if in metric mode (--metric with -f)
	if cfg.MetricMode && cfg.ExecuteScript != "" {
		runMetricMode(ctx, cfg, conn)
		return
	}

	// Check if in direct execution mode (-f or -q or -r)
	if cfg.ExecuteScript != "" || cfg.ExecuteSQL != "" || cfg.ReadScript != "" ||
		cfg.CopyScript != "" {
		runDirectExecution(ctx, cfg, conn)
		return
	}

	// Continue with interactive monitoring mode
	runInteractiveMonitor(ctx, cfg, conn)
}

// runMetricMode runs the metric collection mode with delta calculation
func runMetricMode(ctx context.Context, cfg *config.Config, conn connector.Connector) {
	runner := metric.NewRunner(cfg, conn, cfg.ExecuteScript)
	if err := runner.Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

// runDirectExecution executes script or SQL directly without entering monitoring UI
func runDirectExecution(ctx context.Context, cfg *config.Config, conn connector.Connector) {
	exec := executor.NewExecutor(cfg, conn)

	// Handle different execution modes
	if cfg.CopyScript != "" {
		// Copy script to destination
		handleCopyScript(ctx, cfg, exec)
		return
	}

	if cfg.FindScriptSet {
		// Find/search scripts
		handleFindScript(cfg.FindScript)
		return
	}

	// Execute script or SQL with interval/count support
	count := cfg.Count
	// OS commands default to running once; SQL scripts/queries can loop
	if count == 0 && cfg.ExecuteScript != "" && !scripts.IsSQLScriptInput(cfg.ExecuteScript) {
		count = 1
	}
	interval := cfg.Interval
	infinite := count == 0

	for i := 0; infinite || i < count; i++ {
		if i > 0 && interval > 0 {
			time.Sleep(time.Duration(interval) * time.Second)
		}

		var err error

		if cfg.ExecuteScript != "" {
			// Execute script file (SQL/OS both stream to terminal)
			_, err = exec.ExecuteCommand(ctx, cfg.ExecuteScript)
		} else if cfg.ExecuteSQL != "" {
			// Execute SQL query (streams to terminal)
			_, err = exec.ExecuteAdHocSQL(ctx, cfg.ExecuteSQL)
		}

		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	}
}

// handleReadScript reads and displays script content
func handleReadScript(filename string) {
	content, isBinary, err := scripts.ReadScriptContent(filename)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading script: %v\n", err)
		os.Exit(1)
	}

	if isBinary {
		fmt.Println("This is a binary file, cannot display content")
		os.Exit(1)
	}

	fmt.Print(content)
	if !strings.HasSuffix(content, "\n") {
		fmt.Println()
	}
}

// handleCopyScript copies script to destination
func handleCopyScript(ctx context.Context, cfg *config.Config, exec *executor.Executor) {
	// Parse input: "script dest"
	parts := strings.Fields(cfg.CopyScript)
	if len(parts) < 1 || len(parts) > 2 {
		fmt.Fprintf(os.Stderr, "Invalid format. Usage: --copy 'script [dest]'\n")
		fmt.Fprintf(os.Stderr, "Example: --copy 'we.sql /tmp'\n")
		fmt.Fprintf(os.Stderr, "Example: --copy 'we.sql' (defaults to /tmp)\n")
		os.Exit(1)
	}

	scriptName := parts[0]
	destPath := ""
	if len(parts) == 2 {
		destPath = parts[1]
	}

	destFile, err := exec.CopyScript(ctx, scriptName, destPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error copying script: %v\n", err)
		os.Exit(1)
	}

	if cfg.ConnectionMode == "ssh" {
		fmt.Printf("Script copied successfully to %s:%s\n", cfg.SSHHost, destFile)
	} else {
		fmt.Printf("Script copied successfully to %s\n", destFile)
	}
}

const (
	scriptListTypeWidth = 10
	scriptListFileWidth = 40
	scriptListVerWidth  = 16
	scriptListDescWidth = 64
)

func scriptListRuleWidth() int {
	return scriptListTypeWidth + 1 + scriptListFileWidth + 1 + scriptListVerWidth + 1 + scriptListDescWidth
}

func truncateScriptListText(s string, max int) string {
	if max <= 0 || len(s) <= max {
		return s
	}
	if max <= 3 {
		return s[:max]
	}
	return s[:max-3] + "..."
}

func printScriptListTable(results []scripts.ScriptInfo, eol string) {
	if eol == "" {
		eol = "\n"
	}
	fmt.Printf("%-*s %-*s %-*s %-*s%s",
		scriptListTypeWidth, "TYPE",
		scriptListFileWidth, "FILENAME",
		scriptListVerWidth, "VERSIONS",
		scriptListDescWidth, "DESCRIPTION", eol)
	fmt.Print(strings.Repeat("-", scriptListRuleWidth()) + eol)
	for _, result := range results {
		fmt.Printf("%-*s %-*s %-*s %-*s%s",
			scriptListTypeWidth, result.Type,
			scriptListFileWidth, truncateScriptListText(result.Filename, scriptListFileWidth),
			scriptListVerWidth, truncateScriptListText(result.Versions, scriptListVerWidth),
			scriptListDescWidth, truncateScriptListText(result.Description, scriptListDescWidth),
			eol)
	}
}

// handleFindScript finds and lists scripts
func handleFindScript(pattern string) {
	results, err := scripts.SearchScripts(pattern)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error searching scripts: %v\n", err)
		os.Exit(1)
	}

	if len(results) == 0 {
		fmt.Printf("No scripts found matching pattern: %s\n", pattern)
		return
	}

	printScriptListTable(results, "\n")
	fmt.Printf("\n%d script(s) found\n", len(results))
}

// runInteractiveMonitor runs the interactive monitoring UI
func runInteractiveMonitor(ctx context.Context, cfg *config.Config, conn connector.Connector) {

	// Create collector
	coll := collector.NewCollector(cfg, conn)

	// Create calculator
	calc := calculator.NewCalculator(cfg)

	// Create display
	disp, err := display.NewDisplay(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating display: %v\n", err)
		os.Exit(1)
	}
	defer disp.Close()

	// Create interactive display
	interactiveDisp := display.NewInteractiveDisplay(disp, conn)

	// Create executor
	exec := executor.NewExecutor(cfg, conn)

	// Check if stdin is a terminal
	isTerminal := term.IsTerminal(int(os.Stdin.Fd()))
	logger.DebugStep("tui-start", fmt.Sprintf("interval=%ds count=%d terminal=%v", cfg.Interval, cfg.Count, isTerminal))

	if isTerminal {
		// Setup terminal for raw input
		var err error
		globalOldState, err = term.MakeRaw(int(os.Stdin.Fd()))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error setting up terminal: %v\n", err)
			os.Exit(1)
		}
		defer restoreTerminal()
	}

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM, syscall.SIGQUIT)

	// Channel for keyboard input (only in interactive mode)
	keyChan := make(chan byte, 10)
	rawInputChan := make(chan byte, 100) // Raw input from stdin
	globalInputChan = rawInputChan       // Set global for terminal.PromptInput
	pauseReadChan := make(chan bool, 1)  // Channel to pause/resume keyboard reading
	stopChan := make(chan struct{})
	globalStopChan = stopChan
	if isTerminal {
		// Set up coordinated input reading
		terminal.GetGlobalInputChan = func() <-chan byte {
			return rawInputChan
		}
		terminal.BeforeExit = restoreTerminal

		// Start raw stdin reader (always reads)
		go readStdin(rawInputChan, stopChan)
		// Start keyboard processor (can be paused)
		go processKeyboard(rawInputChan, keyChan, pauseReadChan, stopChan)
	}

	// Main loop
	ticker := time.NewTicker(time.Duration(cfg.Interval) * time.Second)
	defer ticker.Stop()

	iteration := 0
	maxIterations := cfg.Count

	// Run first iteration immediately
	snapshot, err := collectMonitorSnapshot(ctx, cfg, conn, coll, calc)
	if handleMonitorSSHFatal(err) {
		return
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error in iteration: %v\r\n", err)
		if cfg.DebugMode {
			logger.Debug("[tui] initial snapshot failed: %v\n", err)
		}
	} else {
		if isTerminal {
			interactiveDisp.RenderInteractive(snapshot)
		} else {
			disp.Render(snapshot)
		}
	}
	iteration++

	// Check if we should exit after first iteration
	if maxIterations > 0 && iteration >= maxIterations {
		stopGoroutines()
		return
	}

	// Continue with ticker
	for {
		select {
		case <-ticker.C:
			snapshot, err := collectMonitorSnapshot(ctx, cfg, conn, coll, calc)
			if handleMonitorSSHFatal(err) {
				return
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error in iteration: %v\r\n", err)
				if cfg.DebugMode {
					logger.Debug("[tui] ticker snapshot failed: %v\n", err)
				}
			} else {
				if isTerminal {
					interactiveDisp.RenderInteractive(snapshot)
				} else {
					disp.Render(snapshot)
				}
			}
			iteration++

			// Check if we've reached max iterations
			if maxIterations > 0 && iteration >= maxIterations {
				stopGoroutines()
				return
			}

		case <-sigChan:
			if cfg.DebugMode {
				logger.DebugTUIAction("exit", "signal")
			}
			// Restore terminal before exit
			restoreTerminal()
			stopGoroutines()
			return

		case key := <-keyChan:
			// Handle keyboard input in interactive mode
			if isTerminal {
				if cfg.DebugMode {
					logger.DebugTUIKey(key)
				}
				switch key {
				case 'q', 'Q', 27: // q, Q, or ESC key
					if cfg.DebugMode {
						logger.DebugTUIAction("quit", "")
					}
					// Restore terminal before exit
					restoreTerminal()
					stopGoroutines()
					fmt.Println("\r\nExiting...")
					return
				case 'a', 'A':
					if cfg.DebugMode {
						logger.DebugSection("tui-adhoc-sql")
					}
					// Execute ad-hoc SQL
					// Clear screen
					fmt.Print("\033[2J\033[H")

					// Pause keyboard reading for the entire execution
					pauseReadChan <- true

					// Prompt for SQL statement (terminal stays in raw mode)
					fmt.Print("\nEnter SQL statement (ESC to cancel): ")
					sqlStmt := terminal.PromptInput("", 1024)
					if cfg.DebugMode {
						logger.DebugTUIInput("adhoc-sql", sqlStmt)
					}

					if sqlStmt != "" {
						output, err := exec.ExecuteAdHocSQL(ctx, sqlStmt)
						if cfg.DebugMode {
							logger.DebugTUIResult("adhoc-sql", err, len(output))
						}
						if err != nil {
							fmt.Fprintf(os.Stderr, "\r\nError executing SQL: %v\r\n", err)
						}
						// Output already streamed in realtime; only show empty hint.
						if err == nil && output == "" {
							fmt.Printf("\r\n\r\nNo output generated\r\n")
						} else if err != nil {
							fmt.Printf("\r\n")
						}

						// Resume keyboard reading before waiting for key press
						pauseReadChan <- false

						// Wait for key press (read from rawInputChan)
						fmt.Print("\r\nPress any key to continue...")
						<-rawInputChan
						fmt.Println()

						// Pause again for cleanup (will be resumed at end)
						pauseReadChan <- true

						// Resume keyboard reading (same as 's' key)
						pauseReadChan <- false
					} else {
						// User cancelled, resume keyboard reading
						pauseReadChan <- false
					}

					// Refresh display
					if snapshot, snapErr := collectMonitorSnapshot(ctx, cfg, conn, coll, calc); handleMonitorSSHFatal(snapErr) {
						return
					} else if snapErr != nil {
						if cfg.DebugMode {
							logger.Debug("[tui] post-adhoc-sql refresh failed: %v\n", snapErr)
						}
					} else {
						interactiveDisp.RenderInteractive(snapshot)
					}
				case 's', 'S':
					if cfg.DebugMode {
						logger.DebugSection("tui-exec-command")
					}
					// Execute command/script
					// Clear screen
					fmt.Print("\033[2J\033[H")

					// Pause keyboard reading for the entire command execution
					pauseReadChan <- true

					// Prompt for command (terminal stays in raw mode)
					fmt.Print("\nEnter SQL script (.sql) or OS command (ESC to cancel): ")
					command := terminal.PromptInput("", 256)
					if cfg.DebugMode {
						logger.DebugTUIInput("exec-command", command)
					}

					if command != "" {
						fmt.Print("\r\n") // blank line before output

						// Restore terminal to cooked mode so yasql PROMPT/SELECT/DBMS_OUTPUT
						// all align correctly (terminal driver handles LF→CRLF automatically).
						// Raw mode only needed for ESC detection; Ctrl+C still works in cooked mode.
						if globalOldState != nil {
							term.Restore(int(os.Stdin.Fd()), globalOldState)
						}

						// Execute command synchronously (terminal in cooked mode)
						cmdCtx, cmdCancel := context.WithCancel(ctx)
						var output string
						var cmdErr error
						output, cmdErr = exec.ExecuteCommand(cmdCtx, command)
						cmdCancel()

						// Re-enter raw mode for TUI
						if globalOldState != nil {
							newState, rawErr := term.MakeRaw(int(os.Stdin.Fd()))
							if rawErr == nil {
								*globalOldState = *newState
							}
						}

						if cmdErr != nil {
							fmt.Fprintf(os.Stderr, "\r\n\r\nError executing command: %v\r\n\r\n", cmdErr)
						}
						if cfg.DebugMode {
							logger.DebugTUIResult("exec-command", cmdErr, len(output))
						}

						// Output already streamed in realtime for both SQL and OS commands.
						if cmdErr == nil && output == "" {
							fmt.Printf("\r\n\r\nNo output generated\r\n")
						} else if cmdErr != nil {
							fmt.Printf("\r\n")
						}

						// Resume keyboard reading before waiting for key press
						pauseReadChan <- false

						// Wait for key press to continue (read from rawInputChan)
						fmt.Print("\r\nPress any key to continue...")
						<-rawInputChan
						fmt.Print("\r\n")

						// Pause again for cleanup (will be resumed at end)
						pauseReadChan <- true

						// Resume keyboard reading
						pauseReadChan <- false
					} else {
						// User cancelled, resume keyboard reading
						pauseReadChan <- false
					}

					// Refresh display
					if snapshot, snapErr := collectMonitorSnapshot(ctx, cfg, conn, coll, calc); handleMonitorSSHFatal(snapErr) {
						return
					} else if snapErr != nil {
						if cfg.DebugMode {
							logger.Debug("[tui] post-exec-command refresh failed: %v\n", snapErr)
						}
					} else {
						interactiveDisp.RenderInteractive(snapshot)
					}
				case 'f', 'F':
					if cfg.DebugMode {
						logger.DebugSection("tui-find-script")
					}
					// Find/search scripts
					// Clear screen
					fmt.Print("\033[2J\033[H")

					// Pause keyboard reading for the entire execution
					pauseReadChan <- true

					// Prompt for search pattern
					fmt.Print("\nEnter search pattern (regex, .* for all, ESC to cancel): ")
					pattern := terminal.PromptInput("", 256)
					if cfg.DebugMode {
						logger.DebugTUIInput("find-script", pattern)
					}

					if pattern != "" {
						fmt.Print("\r\n\r\n")

						// Search scripts
						results, err := scripts.SearchScripts(pattern)
						if err != nil {
							fmt.Fprintf(os.Stderr, "Error searching scripts: %v\r\n", err)
						} else if len(results) == 0 {
							fmt.Print("No scripts found matching pattern\r\n")
						} else {
							printScriptListTable(results, "\r\n")
							fmt.Printf("\r\n%d script(s) found\r\n", len(results))
						}
						if cfg.DebugMode {
							logger.DebugTUIResult("find-script", err, len(results))
						}

						// Resume keyboard reading before waiting for key press
						pauseReadChan <- false

						// Wait for key press to continue
						fmt.Print("\r\nPress any key to continue...")
						<-rawInputChan
						fmt.Println()

						// Pause again for cleanup
						pauseReadChan <- true

						// Resume keyboard reading
						pauseReadChan <- false
					} else {
						// User cancelled, resume keyboard reading
						pauseReadChan <- false
					}

					// Refresh display
					if snapshot, snapErr := collectMonitorSnapshot(ctx, cfg, conn, coll, calc); handleMonitorSSHFatal(snapErr) {
						return
					} else if snapErr != nil {
						if cfg.DebugMode {
							logger.Debug("[tui] post-find-script refresh failed: %v\n", snapErr)
						}
					} else {
						interactiveDisp.RenderInteractive(snapshot)
					}
				case 'r', 'R':
					if cfg.DebugMode {
						logger.DebugSection("tui-read-script")
					}
					// Read/view script content
					// Clear screen
					fmt.Print("\033[2J\033[H")

					// Pause keyboard reading for the entire execution
					pauseReadChan <- true

					// Prompt for script filename
					fmt.Print("\nEnter script filename (.sql in sql/, others in os/, ESC to cancel): ")
					filename := terminal.PromptInput("", 256)
					if cfg.DebugMode {
						logger.DebugTUIInput("read-script", filename)
					}

					if filename != "" {
						fmt.Print("\r\n\r\n")

						// Read script content
						content, isBinary, err := scripts.ReadScriptContent(filename)
						if err != nil {
							fmt.Fprintf(os.Stderr, "Error reading script: %v\r\n", err)
						} else if isBinary {
							fmt.Print("This is a binary file, cannot display content\r\n")
						} else {
							// Display content with proper line endings for raw mode
							displayContent := strings.ReplaceAll(content, "\n", "\r\n")
							fmt.Print(displayContent)
							fmt.Print("\r\n")
						}
						if cfg.DebugMode {
							if err != nil {
								logger.DebugTUIResult("read-script", err, 0)
							} else if isBinary {
								logger.DebugTUIAction("read-script", "binary file")
							} else {
								logger.DebugTUIResult("read-script", nil, len(content))
							}
						}

						// Resume keyboard reading before waiting for key press
						pauseReadChan <- false

						// Wait for key press to continue
						fmt.Print("\r\nPress any key to continue...")
						<-rawInputChan
						fmt.Println()

						// Pause again for cleanup
						pauseReadChan <- true

						// Resume keyboard reading
						pauseReadChan <- false
					} else {
						// User cancelled, resume keyboard reading
						pauseReadChan <- false
					}

					// Refresh display
					if snapshot, snapErr := collectMonitorSnapshot(ctx, cfg, conn, coll, calc); handleMonitorSSHFatal(snapErr) {
						return
					} else if snapErr != nil {
						if cfg.DebugMode {
							logger.Debug("[tui] post-read-script refresh failed: %v\n", snapErr)
						}
					} else {
						interactiveDisp.RenderInteractive(snapshot)
					}
				case 'c', 'C':
					if cfg.DebugMode {
						logger.DebugSection("tui-copy-script")
					}
					// Copy script to server/local
					// Clear screen
					fmt.Print("\033[2J\033[H")

					// Pause keyboard reading for the entire execution
					pauseReadChan <- true

					// Prompt for script filename and destination
					fmt.Print("\nEnter script filename and destination (e.g., we.sql /tmp, or just we.sql for /tmp, ESC to cancel): ")
					input := terminal.PromptInput("", 512)
					if cfg.DebugMode {
						logger.DebugTUIInput("copy-script", input)
					}

					if input != "" {
						fmt.Print("\r\n\r\n")

						// Parse input: scriptname [destpath]
						parts := strings.Fields(input)
						if len(parts) < 1 || len(parts) > 2 {
							fmt.Print("Invalid format. Usage: <scriptname> [destpath]\r\n")
							fmt.Print("Example: we.sql /tmp\r\n")
							fmt.Print("Example: we.sql (defaults to /tmp)\r\n")
							if cfg.DebugMode {
								logger.DebugTUIAction("copy-script", "invalid-format")
							}
						} else {
							scriptName := parts[0]
							destPath := ""
							if len(parts) == 2 {
								destPath = parts[1]
							}
							if cfg.DebugMode {
								logger.Debug("[tui] copy-script script=%q dest=%q\n", scriptName, destPath)
							}
							// If no destPath specified, CopyScript will default to /tmp

							// Copy script
							destFile, err := exec.CopyScript(ctx, scriptName, destPath)
							if err != nil {
								fmt.Fprintf(os.Stderr, "Error copying script: %v\r\n", err)
							} else {
								if cfg.ConnectionMode == "ssh" {
									fmt.Printf("Script copied successfully to %s:%s\r\n",
										cfg.SSHHost, destFile)
								} else {
									fmt.Printf("Script copied successfully to %s\r\n", destFile)
								}
							}
							if cfg.DebugMode {
								if err != nil {
									logger.DebugTUIResult("copy-script", err, 0)
								} else {
									logger.Debug("[tui] copy-script result=ok dest_file=%q\n", destFile)
								}
							}
						}

						// Resume keyboard reading before waiting for key press
						pauseReadChan <- false

						// Wait for key press to continue
						fmt.Print("\r\nPress any key to continue...")
						<-rawInputChan
						fmt.Println()

						// Pause again for cleanup
						pauseReadChan <- true

						// Resume keyboard reading
						pauseReadChan <- false
					} else {
						// User cancelled, resume keyboard reading
						pauseReadChan <- false
					}

					// Refresh display
					if snapshot, snapErr := collectMonitorSnapshot(ctx, cfg, conn, coll, calc); handleMonitorSSHFatal(snapErr) {
						return
					} else if snapErr != nil {
						if cfg.DebugMode {
							logger.Debug("[tui] post-copy-script refresh failed: %v\n", snapErr)
						}
					} else {
						interactiveDisp.RenderInteractive(snapshot)
					}
				case 'h', 'H':
					if cfg.DebugMode {
						logger.DebugTUIAction("help", "")
					}
					// Show help with terminal restore
					terminal.WithTerminalRestore(globalOldState, func() error {
						// Clear screen and show help
						fmt.Print("\033[2J\033[H")
						fmt.Print(interactiveDisp.ShowHelp())
						return nil
					})

					// Wait for next key press from keyChan to exit help
					<-keyChan // Consume the next key press

					// Refresh display immediately
					if snapshot, snapErr := collectMonitorSnapshot(ctx, cfg, conn, coll, calc); handleMonitorSSHFatal(snapErr) {
						return
					} else if snapErr != nil {
						if cfg.DebugMode {
							logger.Debug("[tui] post-help refresh failed: %v\n", snapErr)
						}
					} else {
						interactiveDisp.RenderInteractive(snapshot)
					}
				default:
					if cfg.DebugMode {
						logger.DebugTUIAction("unhandled", logger.TUIKeyName(key))
					}
				}
			}
		}
	}
}

// readStdin continuously reads from stdin and sends to channel.
// Stops when stopChan is closed or stdin returns an error.
func readStdin(inputChan chan<- byte, stopChan <-chan struct{}) {
	buf := make([]byte, 1)
	for {
		select {
		case <-stopChan:
			return
		default:
			n, err := os.Stdin.Read(buf)
			if err != nil {
				return
			}
			if n > 0 {
				select {
				case inputChan <- buf[0]:
				case <-stopChan:
					return
				}
			}
		}
	}
}

// processKeyboard processes keyboard input and can be paused.
// Stops when stopChan is closed.
func processKeyboard(inputChan <-chan byte, keyChan chan<- byte, pauseChan <-chan bool, stopChan <-chan struct{}) {
	paused := false

	for {
		// Check if we should stop
		select {
		case <-stopChan:
			return
		default:
		}

		// Check if we should pause
		select {
		case shouldPause := <-pauseChan:
			paused = shouldPause
		case <-stopChan:
			return
		default:
		}

		// If paused, don't process input
		if paused {
			time.Sleep(10 * time.Millisecond)
			continue
		}

		// Get input from stdin reader
		select {
		case buf := <-inputChan:
			// Ctrl+C - exit program
			if buf == 3 {
				restoreTerminal()
				fmt.Println("\r\nExiting...")
				os.Exit(0)
			}

			// Check if this is ESC key (potential start of escape sequence)
			if buf == 27 {
				// Try to peek if there are more bytes coming (escape sequence)
				extraBuf := make([]byte, 2)
				extraN := 0

				// Wait only 20ms to see if more bytes arrive
				timeout := time.After(20 * time.Millisecond)
				gotExtra := false

			readExtra:
				for i := 0; i < 2; i++ {
					select {
					case b := <-inputChan:
						extraBuf[extraN] = b
						extraN++
					case <-timeout:
						break readExtra
					}
				}

				// Check if it's an arrow key
				if extraN == 2 && extraBuf[0] == 91 {
					// Arrow key: ESC [ A/B/C/D
					switch extraBuf[1] {
					case 65: // Up arrow
						keyChan <- 200
					case 66: // Down arrow
						keyChan <- 201
					case 67: // Right arrow
						keyChan <- 202
					case 68: // Left arrow
						keyChan <- 203
					}
					gotExtra = true
				}

				if !gotExtra {
					// Not an arrow key, send ESC first
					keyChan <- 27
					// Then send the extra bytes we read
					for i := 0; i < extraN; i++ {
						keyChan <- extraBuf[i]
					}
				}
			} else {
				// Regular key
				keyChan <- buf
			}
		case <-time.After(100 * time.Millisecond):
			// Timeout, continue loop
		case <-stopChan:
			return
		}
	}
}

// collectMonitorSnapshot collects a snapshot; in SSH mode it reconnects and retries
// up to MonitorSSHMaxRetries times on recoverable connection errors.
func collectMonitorSnapshot(ctx context.Context, cfg *config.Config, conn connector.Connector, coll *collector.Collector, calc *calculator.Calculator) (*models.Snapshot, error) {
	snapshot, err := collectSnapshot(ctx, coll, calc)
	if err == nil || cfg.ConnectionMode != "ssh" || !connector.IsRecoverableSSHError(err) {
		return snapshot, err
	}

	sshConn, ok := conn.(*connector.SSHConnector)
	if !ok {
		return nil, err
	}

	lastErr := err
	for attempt := 1; attempt <= connector.MonitorSSHMaxRetries; attempt++ {
		fmt.Fprintf(os.Stderr, "\r\n[WARN] SSH connection lost, retry %d/%d: %v\r\n",
			attempt, connector.MonitorSSHMaxRetries, lastErr)
		if cfg.DebugMode {
			logger.Debug("[tui] ssh retry %d/%d: %v\n", attempt, connector.MonitorSSHMaxRetries, lastErr)
		}

		if reconnErr := sshConn.Reconnect(ctx); reconnErr != nil {
			lastErr = reconnErr
		} else if snapshot, err = collectSnapshot(ctx, coll, calc); err == nil {
			fmt.Fprintf(os.Stderr, "\r\n[INFO] SSH reconnected (attempt %d/%d)\r\n",
				attempt, connector.MonitorSSHMaxRetries)
			return snapshot, nil
		} else if !connector.IsRecoverableSSHError(err) {
			return nil, err
		} else {
			lastErr = err
		}

		if attempt < connector.MonitorSSHMaxRetries {
			time.Sleep(time.Duration(attempt) * 500 * time.Millisecond)
		}
	}

	return nil, fmt.Errorf("%w: %v", connector.ErrSSHRetriesExhausted, lastErr)
}

func handleMonitorSSHFatal(err error) bool {
	if err == nil || !errors.Is(err, connector.ErrSSHRetriesExhausted) {
		return false
	}
	restoreTerminal()
	stopGoroutines()
	fmt.Fprintf(os.Stderr, "\r\nSSH connection lost after %d retries, exiting.\r\n", connector.MonitorSSHMaxRetries)
	os.Exit(1)
	return true
}

// collectSnapshot collects a data snapshot
func collectSnapshot(ctx context.Context, coll *collector.Collector, calc *calculator.Calculator) (*models.Snapshot, error) {
	collectStart := time.Now()
	timestamp := time.Now()
	logger.DebugSection("tui-collect-snapshot")

	// Collect data
	sysStats, err := coll.CollectSysStats(ctx)
	if err != nil {
		logger.Debug("[tui] collectSnapshot failed at sysstat after %.3fs: %v\n", time.Since(collectStart).Seconds(), err)
		return nil, fmt.Errorf("failed to collect sysstat: %w", err)
	}

	systemEvents, err := coll.CollectSystemEvents(ctx)
	if err != nil {
		logger.Debug("[tui] collectSnapshot failed at system_events after %.3fs: %v\n", time.Since(collectStart).Seconds(), err)
		return nil, fmt.Errorf("failed to collect system events: %w", err)
	}

	sessionMetrics, err := coll.CollectSessionMetrics(ctx)
	if err != nil {
		logger.Debug("[tui] collectSnapshot failed at session_metrics after %.3fs: %v\n", time.Since(collectStart).Seconds(), err)
		return nil, fmt.Errorf("failed to collect session metrics: %w", err)
	}

	sessionDetails, err := coll.CollectSessionDetails(ctx)
	if err != nil {
		logger.Debug("[tui] collectSnapshot failed at session_details after %.3fs: %v\n", time.Since(collectStart).Seconds(), err)
		return nil, fmt.Errorf("failed to collect session details: %w", err)
	}

	collectDuration := time.Since(collectStart)

	// Calculate deltas and rankings
	sysStats = calc.CalculateSysStatDeltas(sysStats, timestamp)
	systemEvents = calc.CalculateSystemEventDeltas(systemEvents)
	sessionMetrics = calc.RankSessionMetrics(sessionMetrics, timestamp)

	totalDuration := time.Since(collectStart)
	logger.Debug("[tui] collectSnapshot ok collect=%.3fs total=%.3fs sysStats=%d events=%d sessionMetrics=%d sessionDetails=%d\n",
		collectDuration.Seconds(), totalDuration.Seconds(),
		len(sysStats), len(systemEvents), len(sessionMetrics), len(sessionDetails))
	if collectDuration > 500*time.Millisecond {
		fmt.Fprintf(os.Stderr, "\r\n[WARN] Snapshot collection took %.2fs (collect=%.2fs)\r\n",
			totalDuration.Seconds(), collectDuration.Seconds())
		logger.Debug("[tui] collectSnapshot slow: collect=%.3fs total=%.3fs\n",
			collectDuration.Seconds(), totalDuration.Seconds())
	}

	// Create snapshot
	return &models.Snapshot{
		Timestamp:      timestamp,
		SysStats:       sysStats,
		SystemEvents:   systemEvents,
		SessionMetrics: sessionMetrics,
		SessionDetails: sessionDetails,
	}, nil
}
