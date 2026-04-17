package connector

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/logger"
)

// LocalConnector implements Connector for local yasql execution
type LocalConnector struct {
	cfg       *config.Config
	connected bool
}

// NewLocalConnector creates a new local connector
func NewLocalConnector(cfg *config.Config) *LocalConnector {
	return &LocalConnector{
		cfg: cfg,
	}
}

// Connect establishes the connection (for local, just verify yasql is available)
func (c *LocalConnector) Connect(ctx context.Context) error {
	// Test if yasql is available
	cmd := exec.CommandContext(ctx, c.cfg.YasqlPath, "-v")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("yasql command not found or not executable at path '%s'.\nPlease ensure yasql is installed and the path is correct.\nYou can specify yasql path with --yasql option", c.cfg.YasqlPath)
	}
	c.connected = true
	return nil
}

// ExecuteQuery executes a SQL query via yasql
func (c *LocalConnector) ExecuteQuery(ctx context.Context, sql string) ([][]string, error) {
	if !c.connected {
		return nil, fmt.Errorf("not connected")
	}

	// Prepare yasql command with -S flag for silent mode and -c for SQL execution
	args := []string{"-S"}

	// Add connection string
	if c.cfg.ConnectString != "" {
		args = append(args, c.cfg.ConnectString)
	}

	// Add -c flag with SQL command
	args = append(args, "-c", sql)

	cmd := exec.CommandContext(ctx, c.cfg.YasqlPath, args...)

	if c.cfg.DebugMode {
		logger.Debug("Executing SQL:\n%s\n", sql)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("yasql execution failed: %w, output: %s", err, string(output))
	}

	// Parse output and check for errors
	return parseYasqlOutput(string(output))
}

// ExecuteQueryWithHeader executes a SQL query and returns header + data rows
func (c *LocalConnector) ExecuteQueryWithHeader(ctx context.Context, sql string) (header []string, rows [][]string, err error) {
	if !c.connected {
		return nil, nil, fmt.Errorf("not connected")
	}

	// Prepare yasql command with -S flag for silent mode and -c for SQL execution
	args := []string{"-S"}

	// Add connection string
	if c.cfg.ConnectString != "" {
		args = append(args, c.cfg.ConnectString)
	}

	// Add -c flag with SQL command
	args = append(args, "-c", sql)

	cmd := exec.CommandContext(ctx, c.cfg.YasqlPath, args...)

	if c.cfg.DebugMode {
		logger.Debug("Executing SQL:\n%s\n", sql)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, nil, fmt.Errorf("yasql execution failed: %w, output: %s", err, string(output))
	}

	// Parse output with header
	return ParseYasqlOutputWithHeader(string(output))
}

// Close closes the connection
func (c *LocalConnector) Close() error {
	c.connected = false
	return nil
}

// IsConnected returns connection status
func (c *LocalConnector) IsConnected() bool {
	return c.connected
}
