package metric

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/connector"
)

// Runner orchestrates metric collection and display
type Runner struct {
	cfg     *config.Config
	conn    connector.Connector
	sqlFile string
}

// NewRunner creates a new metric runner
func NewRunner(cfg *config.Config, conn connector.Connector, sqlFile string) *Runner {
	return &Runner{
		cfg:     cfg,
		conn:    conn,
		sqlFile: sqlFile,
	}
}

// Run starts the metric collection loop
func (r *Runner) Run(ctx context.Context) error {
	// Create collector
	collector := NewCollector(r.conn, r.sqlFile)

	// First collection to detect columns
	firstSnapshot, err := collector.Collect(ctx)
	if err != nil {
		return fmt.Errorf("failed to collect initial snapshot: %w", err)
	}
	if firstSnapshot == nil {
		return fmt.Errorf("no data returned from query")
	}

	// Get column info
	columnInfo := collector.GetColumnInfo()
	if columnInfo == nil {
		return fmt.Errorf("failed to detect column info")
	}

	// Create calculator with column info
	calc := NewCalculator(columnInfo)

	// Create display
	disp := NewDisplay(r.sqlFile)

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	// Use interval from config
	interval := time.Duration(r.cfg.Interval) * time.Second
	if interval <= 0 {
		interval = time.Second
	}

	// Main loop
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	iteration := 0
	maxIterations := r.cfg.Count

	// Process first snapshot (no delta yet)
	calc.Calculate(firstSnapshot)

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-sigChan:
			fmt.Println("\nReceived interrupt signal, exiting...")
			return nil
		case <-ticker.C:
			// Collect snapshot
			snapshot, err := collector.Collect(ctx)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error collecting snapshot: %v\n", err)
				continue
			}

			// Calculate result
			result := calc.Calculate(snapshot)
			if result == nil {
				continue
			}

			iteration++

			// Render and display
			output := disp.Render(result, iteration, maxIterations)
			fmt.Print(output)
			fmt.Println()

			// Check if we've reached max iterations
			if maxIterations > 0 && iteration >= maxIterations {
				return nil
			}
		}
	}
}
