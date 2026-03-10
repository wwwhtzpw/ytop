package connector

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/logger"
	"github.com/yihan/ytop/internal/utils"
)

// SSHConnector implements Connector for SSH-based yasql execution
type SSHConnector struct {
	cfg       *config.Config
	pool      *SSHConnectionPool
	connected bool
}

// NewSSHConnector creates a new SSH connector
func NewSSHConnector(cfg *config.Config) *SSHConnector {
	return &SSHConnector{
		cfg:  cfg,
		pool: NewSSHConnectionPool(cfg, 10), // Pool size of 10
	}
}

// Connect establishes SSH connection
func (c *SSHConnector) Connect(ctx context.Context) error {
	// Connect the pool
	if err := c.pool.Connect(ctx); err != nil {
		return err
	}

	c.connected = true

	if c.cfg.DebugMode {
		logger.Debug("SSH connector initialized with connection pool\n")
	}

	// Verify yasql is available on remote host
	session, err := c.pool.NewSession()
	if err != nil {
		return fmt.Errorf("failed to create SSH session for yasql verification: %w", err)
	}
	defer session.Close()

	// Build command to check yasql
	checkCmd := c.cfg.YasqlPath + " -v"
	if c.cfg.SourceCmd != "" {
		checkCmd = c.cfg.SourceCmd + " && " + checkCmd
	}

	if c.cfg.DebugMode {
		logger.Debug("Checking yasql command: %s\n", checkCmd)
	}

	output, err := session.CombinedOutput(checkCmd)
	if err != nil {
		return fmt.Errorf("yasql command not found or not executable on remote host '%s' at path '%s'.\nPlease ensure yasql is installed on the remote host and the path is correct.\nYou can specify yasql path with --yasql option.\nCommand output: %s", c.cfg.SSHHost, c.cfg.YasqlPath, string(output))
	}

	if c.cfg.DebugMode {
		logger.Debug("yasql verification successful: %s\n", string(output))
	}

	return nil
}

// ExecuteQuery executes a SQL query via SSH + yasql
func (c *SSHConnector) ExecuteQuery(ctx context.Context, sql string) ([][]string, error) {
	if !c.connected {
		return nil, fmt.Errorf("not connected")
	}

	// Create new session from pool
	session, err := c.pool.NewSession()
	if err != nil {
		return nil, err
	}
	defer session.Close()

	// Build command
	var cmdParts []string

	// Add source command if specified
	if c.cfg.SourceCmd != "" {
		cmdParts = append(cmdParts, c.cfg.SourceCmd)
	}

	// Prepare yasql command with -S flag for silent mode and -c for SQL execution
	yasqlCmd := fmt.Sprintf("%s -S", c.cfg.YasqlPath)

	if c.cfg.ConnectString != "" {
		yasqlCmd += " " + utils.ShellEscape(c.cfg.ConnectString)
	}

	// Add -c flag with SQL command
	yasqlCmd += " -c " + utils.ShellEscape(sql)

	fullCmd := yasqlCmd
	if len(cmdParts) > 0 {
		fullCmd = strings.Join(cmdParts, " && ") + " && " + fullCmd
	}

	if c.cfg.DebugMode {
		logger.Debug("SSH command: %s\n", fullCmd)
		logger.Debug("SQL: %s\n", sql)
	}

	// Execute command
	output, err := session.CombinedOutput(fullCmd)
	if err != nil {
		return nil, fmt.Errorf("SSH command execution failed: %w, output: %s", err, string(output))
	}

	if c.cfg.DebugMode {
		logger.Debug("Output: %s\n", string(output))
	}

	// Parse output and check for errors
	return parseYasqlOutput(string(output))
}

// Close closes the SSH connection
func (c *SSHConnector) Close() error {
	if c.pool != nil {
		return c.pool.Close()
	}
	return nil
}

// IsConnected returns connection status
func (c *SSHConnector) IsConnected() bool {
	return c.connected && c.pool != nil && c.pool.IsConnected()
}

// ExecuteCommand executes a shell command via SSH and returns raw output
func (c *SSHConnector) ExecuteCommand(ctx context.Context, command string) (string, error) {
	if !c.connected {
		return "", fmt.Errorf("not connected")
	}

	// Create new session from pool
	session, err := c.pool.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	if c.cfg.DebugMode {
		logger.Debug("SSH command: %s\n", command)
	}

	// Execute command
	output, err := session.CombinedOutput(command)
	if err != nil {
		return string(output), fmt.Errorf("SSH command execution failed: %w", err)
	}

	if c.cfg.DebugMode {
		logger.Debug("Output: %s\n", string(output))
	}

	return string(output), nil
}

// ExecuteCommandRealtime executes a command via SSH with real-time output streaming
func (c *SSHConnector) ExecuteCommandRealtime(ctx context.Context, command string) (string, error) {
	if !c.connected {
		return "", fmt.Errorf("not connected")
	}

	// Create new session from pool
	session, err := c.pool.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	if c.cfg.DebugMode {
		logger.Debug("SSH command (realtime): %s\n", command)
	}

	// Get stdout and stderr pipes
	stdout, err := session.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create stdout pipe: %w", err)
	}

	stderr, err := session.StderrPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	// Start the command
	if err := session.Start(command); err != nil {
		return "", fmt.Errorf("failed to start SSH command: %w", err)
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
		// Send SIGTERM to remote process when context is cancelled
		session.Signal(ssh.SIGTERM)
		// Give it a moment, then force close
		time.Sleep(100 * time.Millisecond)
		session.Close()
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
	err = session.Wait()

	if ctx.Err() == context.Canceled {
		return outputBuffer.String(), nil // Context cancelled, not an error
	}

	if err != nil {
		return outputBuffer.String(), fmt.Errorf("SSH command execution failed: %w", err)
	}

	return outputBuffer.String(), nil
}

