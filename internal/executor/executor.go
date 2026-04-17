package executor

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/logger"
	"github.com/yihan/ytop/internal/scripts"
	"github.com/yihan/ytop/internal/terminal"
	"github.com/yihan/ytop/internal/utils"
)

// Executor handles script and command execution
type Executor struct {
	cfg  *config.Config
	conn connector.Connector
}

// NewExecutor creates a new executor
func NewExecutor(cfg *config.Config, conn connector.Connector) *Executor {
	return &Executor{
		cfg:  cfg,
		conn: conn,
	}
}

// ExecuteCommand executes a command or script
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

// executeSQLScript executes a SQL script
func (e *Executor) executeSQLScript(ctx context.Context, scriptName string) (string, error) {
	// Load script (handles both embedded and filesystem paths)
	scriptContent, err := scripts.GetSQLScript(scriptName)
	if err != nil {
		return "", err
	}

	if e.cfg.DebugMode {
		logger.Debug("Loaded script content:\n%s\n", scriptContent)
	}

	// Find all variables (&var or &&var)
	variables := e.findVariables(scriptContent)

	// Prompt for variable values
	varMap := make(map[string]string)
	for _, variable := range variables {
		// Display variable with its prefix; Enter without typing = empty value (replace with "")
		value := terminal.PromptInput(fmt.Sprintf("\r\nEnter value for %s: ", variable), 256)
		varMap[variable] = value
	}

	// Replace variables with precise matching
	for variable, value := range varMap {
		scriptContent = e.replaceVariable(scriptContent, variable, value)
	}

	// Execute based on connection mode
	if e.cfg.ConnectionMode == "ssh" && e.isLocalAuth() {
		return e.executeSQLViaSSHUpload(ctx, scriptContent, scriptName)
	}

	return e.executeSQLDirect(ctx, scriptContent)
}

// executeSQLViaSSHUpload uploads script to remote host and executes
func (e *Executor) executeSQLViaSSHUpload(ctx context.Context, scriptContent, scriptName string) (string, error) {
	// Create temporary script file
	tmpFile := fmt.Sprintf("/tmp/ytop_%s_%d.sql", filepath.Base(scriptName), os.Getpid())

	// Upload script content via SSH
	sshConn, ok := e.conn.(*connector.SSHConnector)
	if !ok {
		return "", fmt.Errorf("not an SSH connection")
	}

	// Ensure cleanup happens unless debug mode
	defer func() {
		if !e.cfg.DebugMode {
			cleanupCmd := fmt.Sprintf("rm -f %s", tmpFile)
			sshConn.ExecuteCommand(ctx, cleanupCmd)
		}
	}()

	// Write script to remote host
	uploadCmd := fmt.Sprintf("cat > %s << 'YASTOP_EOF'\n%s\nexit\nYASTOP_EOF", tmpFile, scriptContent)
	if _, err := sshConn.ExecuteCommand(ctx, uploadCmd); err != nil {
		return "", fmt.Errorf("failed to upload script: %w", err)
	}

	// Execute script with -S flag to suppress connection info
	execCmd := fmt.Sprintf("%s -S %s @%s", e.cfg.YasqlPath, e.cfg.ConnectString, tmpFile)
	if e.cfg.SourceCmd != "" {
		execCmd = e.cfg.SourceCmd + " && " + execCmd
	}

	if e.cfg.DebugMode {
		logger.Debug("Executing SQL script via SSH: %s\n", execCmd)
	}

	output, err := sshConn.ExecuteCommand(ctx, execCmd)
	return output, err
}

// executeSQLDirect executes SQL directly via local yasql with temp file
func (e *Executor) executeSQLDirect(ctx context.Context, scriptContent string) (string, error) {
	// Create temporary script file
	tmpFile := fmt.Sprintf("/tmp/ytop_%d.sql", os.Getpid())

	// Write script content to temp file
	if err := os.WriteFile(tmpFile, []byte(scriptContent), 0644); err != nil {
		return "", fmt.Errorf("failed to write temp script: %w", err)
	}

	// Ensure cleanup
	defer func() {
		if !e.cfg.DebugMode {
			os.Remove(tmpFile)
		}
	}()

	// Build yasql command with @file
	args := []string{"-S"}
	if e.cfg.ConnectString != "" {
		args = append(args, e.cfg.ConnectString)
	}
	args = append(args, "@"+tmpFile)

	if e.cfg.DebugMode {
		logger.Debug("Executing SQL script locally: %s %v\n", e.cfg.YasqlPath, args)
	}

	cmd := exec.CommandContext(ctx, e.cfg.YasqlPath, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("yasql execution failed: %w", err)
	}

	return string(output), nil
}

// executeOSCommand executes an OS command or script
func (e *Executor) executeOSCommand(ctx context.Context, input string) (string, error) {
	// Check if it's an embedded OS script
	if !strings.Contains(input, " ") {
		// Might be a script name
		scriptContent, err := scripts.GetOSScript(input)
		if err == nil {
			// Execute embedded script
			return e.executeOSScript(ctx, scriptContent)
		}
		// Input looks like a script name (e.g. db_size.sl) but script not found:
		// do not run as shell command to avoid SSH and confusing "command not found"
		if strings.Contains(input, ".") {
			return "", fmt.Errorf("script not found: %s", input)
		}
	}

	// Execute as shell command
	if e.cfg.ConnectionMode == "ssh" {
		return e.executeOSCommandViaSSH(ctx, input)
	}

	return e.executeOSCommandLocal(ctx, input)
}

// executeOSCommandViaSSH executes OS command via SSH with real-time output
func (e *Executor) executeOSCommandViaSSH(ctx context.Context, command string) (string, error) {
	sshConn, ok := e.conn.(*connector.SSHConnector)
	if !ok {
		return "", fmt.Errorf("not an SSH connection")
	}

	if e.cfg.SourceCmd != "" {
		command = e.cfg.SourceCmd + " && " + command
	}

	return sshConn.ExecuteCommandRealtime(ctx, command)
}

// executeOSCommandLocal executes OS command locally with real-time output
func (e *Executor) executeOSCommandLocal(ctx context.Context, command string) (string, error) {
	cmd := exec.CommandContext(ctx, "bash", "-c", command)

	// Set process group ID so we can kill the entire process tree (platform-specific)
	setProcAttributes(cmd)

	// Create pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create stdout pipe: %w", err)
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	// Start the command
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("failed to start command: %w", err)
	}

	// Buffer to collect all output
	var outputBuffer strings.Builder
	var bufferMutex sync.Mutex

	// Channel to signal completion
	done := make(chan bool, 2)

	// Track if context was cancelled
	ctxDone := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(ctxDone)
		// Kill the entire process group when context is cancelled (platform-specific)
		killProcessGroup(cmd)
	}()

	// Read stdout in real-time byte by byte for immediate display
	go func() {
		buf := make([]byte, 1)
		for {
			select {
			case <-ctxDone:
				// Context cancelled, stop reading
				done <- true
				return
			default:
				n, err := stdout.Read(buf)
				if n > 0 {
					// In raw mode, convert \n to \r\n for proper line breaks
					if buf[0] == '\n' {
						os.Stdout.Write([]byte("\r\n"))
						bufferMutex.Lock()
						outputBuffer.WriteByte('\n')
						bufferMutex.Unlock()
					} else {
						// Regular character (including \r)
						os.Stdout.Write(buf[:n])
						bufferMutex.Lock()
						outputBuffer.Write(buf[:n])
						bufferMutex.Unlock()
					}
				}
				if err != nil {
					done <- true
					return
				}
			}
		}
	}()

	// Read stderr in real-time byte by byte for immediate display
	go func() {
		buf := make([]byte, 1)
		for {
			select {
			case <-ctxDone:
				// Context cancelled, stop reading
				done <- true
				return
			default:
				n, err := stderr.Read(buf)
				if n > 0 {
					// In raw mode, convert \n to \r\n for proper line breaks
					if buf[0] == '\n' {
						os.Stderr.Write([]byte("\r\n"))
						bufferMutex.Lock()
						outputBuffer.WriteByte('\n')
						bufferMutex.Unlock()
					} else {
						// Regular character (including \r)
						os.Stderr.Write(buf[:n])
						bufferMutex.Lock()
						outputBuffer.Write(buf[:n])
						bufferMutex.Unlock()
					}
				}
				if err != nil {
					done <- true
					return
				}
			}
		}
	}()

	// Wait for both goroutines to finish
	<-done
	<-done

	// Wait for command to complete
	err = cmd.Wait()

	if ctx.Err() == context.Canceled {
		return outputBuffer.String(), nil // Context cancelled, not an error
	}

	if err != nil {
		return outputBuffer.String(), fmt.Errorf("command failed: %w", err)
	}

	return outputBuffer.String(), nil
}

// executeOSScript executes an OS script
func (e *Executor) executeOSScript(ctx context.Context, scriptContent string) (string, error) {
	if e.cfg.ConnectionMode == "ssh" {
		return e.executeOSCommandViaSSH(ctx, scriptContent)
	}
	return e.executeOSCommandLocal(ctx, scriptContent)
}

// ExecuteAdHocSQL executes a single SQL statement directly
func (e *Executor) ExecuteAdHocSQL(ctx context.Context, sql string) (string, error) {
	sql = strings.TrimSpace(sql)
	if sql == "" {
		return "", fmt.Errorf("empty SQL statement")
	}

	// Execute based on connection mode
	if e.cfg.ConnectionMode == "ssh" {
		return e.executeAdHocSQLViaSSH(ctx, sql)
	}

	return e.executeAdHocSQLLocal(ctx, sql)
}

// executeAdHocSQLViaSSH executes ad-hoc SQL via SSH
func (e *Executor) executeAdHocSQLViaSSH(ctx context.Context, sql string) (string, error) {
	sshConn, ok := e.conn.(*connector.SSHConnector)
	if !ok {
		return "", fmt.Errorf("not an SSH connection")
	}

	// Build yasql command with -c flag
	// Use ShellEscape to properly escape the SQL statement
	yasqlCmd := fmt.Sprintf("%s -S %s -c %s",
		e.cfg.YasqlPath,
		utils.ShellEscape(e.cfg.ConnectString),
		utils.ShellEscape(sql))

	if e.cfg.SourceCmd != "" {
		yasqlCmd = e.cfg.SourceCmd + " && " + yasqlCmd
	}

	if e.cfg.DebugMode {
		logger.Debug("Executing ad-hoc SQL via SSH: %s\n", yasqlCmd)
	}

	return sshConn.ExecuteCommand(ctx, yasqlCmd)
}

// executeAdHocSQLLocal executes ad-hoc SQL locally
func (e *Executor) executeAdHocSQLLocal(ctx context.Context, sql string) (string, error) {
	// Build yasql command with -c flag
	args := []string{"-S"}

	// Add connection string
	if e.cfg.ConnectString != "" {
		args = append(args, e.cfg.ConnectString)
	}

	// Add -c flag with SQL statement
	args = append(args, "-c", sql)

	if e.cfg.DebugMode {
		logger.Debug("Executing ad-hoc SQL locally: %s %v\n", e.cfg.YasqlPath, args)
	}

	cmd := exec.CommandContext(ctx, e.cfg.YasqlPath, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("yasql execution failed: %w", err)
	}

	return string(output), nil
}

// findVariables finds all &var and &&var in script
func (e *Executor) findVariables(script string) []string {
	// Match &var or &&var where var is followed by non-word character or end of string
	// This ensures &1 doesn't match in &11
	re := regexp.MustCompile(`(&&?)(\w+)\b`)
	matches := re.FindAllStringSubmatch(script, -1)

	seen := make(map[string]struct {
		name   string
		isDouble bool
	})
	var variables []string

	for _, match := range matches {
		if len(match) > 2 {
			prefix := match[1]  // & or &&
			varName := match[2] // variable name
			isDouble := prefix == "&&"

			key := prefix + varName

			// Check if we've seen this exact variable (with same prefix)
			if existing, exists := seen[varName]; exists {
				// If we've seen &var but now see &&var, or vice versa
				// treat them as different variables
				if existing.isDouble != isDouble {
					// Keep both versions
					if !utils.Contains(variables, key) {
						variables = append(variables, key)
					}
				}
			} else {
				seen[varName] = struct {
					name   string
					isDouble bool
				}{varName, isDouble}
				variables = append(variables, key)
			}
		}
	}

	return variables
}

// replaceVariable replaces a variable in script with precise matching
func (e *Executor) replaceVariable(script, variable, value string) string {
	// Use word boundary to ensure exact match
	// For example, replacing &1 won't affect &11
	pattern := regexp.QuoteMeta(variable) + `\b`
	re := regexp.MustCompile(pattern)
	return re.ReplaceAllString(script, value)
}

// splitSQLStatements splits SQL script into individual statements
func (e *Executor) splitSQLStatements(script string) []string {
	// Simple split by semicolon (can be improved for complex cases)
	statements := strings.Split(script, ";")
	var result []string

	for _, stmt := range statements {
		stmt = strings.TrimSpace(stmt)
		if stmt != "" {
			result = append(result, stmt)
		}
	}

	return result
}

// isSQLPlusCommand checks if statement is a SQL*Plus command
func (e *Executor) isSQLPlusCommand(stmt string) bool {
	// Don't filter any commands - all SQL scripts have been tested and can be executed directly
	return false
}

// isLocalAuth checks if using local authentication (/ as sysdba)
func (e *Executor) isLocalAuth() bool {
	connectStr := strings.ToLower(strings.TrimSpace(e.cfg.ConnectString))
	return strings.Contains(connectStr, "/ as sysdba") ||
	       strings.Contains(connectStr, "/as sysdba") ||
	       connectStr == "/"
}

// CopyScript copies a script file to specified destination
// For SSH mode: copies to remote server
// For local mode: copies to local filesystem
// Returns destination file path and error
func (e *Executor) CopyScript(ctx context.Context, scriptName, destPath string) (string, error) {
	// Load script content (handles both .sql and other files)
	var scriptContent string
	var err error

	if strings.HasSuffix(scriptName, ".sql") {
		scriptContent, err = scripts.GetSQLScript(scriptName)
	} else {
		scriptContent, err = scripts.GetOSScript(scriptName)
	}

	if err != nil {
		return "", fmt.Errorf("failed to load script: %w", err)
	}

	// Default to /tmp if no destination specified
	if destPath == "" {
		destPath = "/tmp"
	}

	// Ensure destination path ends with /
	if !strings.HasSuffix(destPath, "/") {
		destPath = destPath + "/"
	}

	destFile := destPath + filepath.Base(scriptName)

	// Copy based on connection mode
	if e.cfg.ConnectionMode == "ssh" {
		return destFile, e.copyScriptViaSSH(ctx, scriptContent, destFile)
	}

	return destFile, e.copyScriptLocal(scriptContent, destFile)
}

// copyScriptViaSSH copies script to remote server via SSH
func (e *Executor) copyScriptViaSSH(ctx context.Context, scriptContent, destFile string) error {
	sshConn, ok := e.conn.(*connector.SSHConnector)
	if !ok {
		return fmt.Errorf("not an SSH connection")
	}

	// Upload script content via SSH using printf to avoid extra newline
	// Escape single quotes in content for shell
	escapedContent := strings.ReplaceAll(scriptContent, "'", "'\\''")
	uploadCmd := fmt.Sprintf("printf '%%s' '%s' > %s", escapedContent, destFile)
	if _, err := sshConn.ExecuteCommand(ctx, uploadCmd); err != nil {
		return fmt.Errorf("failed to copy script to remote server: %w", err)
	}

	// Set file permissions
	chmodCmd := fmt.Sprintf("chmod 644 %s", destFile)
	if _, err := sshConn.ExecuteCommand(ctx, chmodCmd); err != nil {
		logger.Debug("Failed to set file permissions: %v", err)
	}

	// Verify file exists and check size
	verifyCmd := fmt.Sprintf("test -f %s && wc -c < %s", destFile, destFile)
	output, err := sshConn.ExecuteCommand(ctx, verifyCmd)
	if err != nil {
		return fmt.Errorf("failed to verify copied file: %w", err)
	}

	// Check if file size matches
	remoteSize := strings.TrimSpace(output)
	expectedSize := fmt.Sprintf("%d", len(scriptContent))
	if remoteSize != expectedSize {
		return fmt.Errorf("file size mismatch: expected %s bytes, got %s bytes", expectedSize, remoteSize)
	}

	return nil
}

// copyScriptLocal copies script to local filesystem
func (e *Executor) copyScriptLocal(scriptContent, destFile string) error {
	// Write to local file
	if err := os.WriteFile(destFile, []byte(scriptContent), 0644); err != nil {
		return fmt.Errorf("failed to copy script to local path: %w", err)
	}

	// Verify file exists and check size
	fileInfo, err := os.Stat(destFile)
	if err != nil {
		return fmt.Errorf("failed to verify copied file: %w", err)
	}

	// Check if file size matches
	if fileInfo.Size() != int64(len(scriptContent)) {
		return fmt.Errorf("file size mismatch: expected %d bytes, got %d bytes", len(scriptContent), fileInfo.Size())
	}

	return nil
}
