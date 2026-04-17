package connector

import "context"

// Connector defines the interface for database connections
type Connector interface {
	// Connect establishes the connection
	Connect(ctx context.Context) error

	// ExecuteQuery executes a SQL query and returns rows as string slices
	ExecuteQuery(ctx context.Context, sql string) ([][]string, error)

	// ExecuteQueryWithHeader executes a SQL query and returns header + data rows
	ExecuteQueryWithHeader(ctx context.Context, sql string) (header []string, rows [][]string, err error)

	// Close closes the connection
	Close() error

	// IsConnected returns true if the connection is active
	IsConnected() bool
}
