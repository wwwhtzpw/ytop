package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/subcommand"
)

func runSesstat() {
	// Check for help flag anywhere in arguments
	for _, arg := range os.Args[2:] {
		if arg == "--help" || arg == "help" || arg == "-help" {
			config.PrintSesstatUsage()
			return
		}
	}

	// Parse flags
	fs := flag.NewFlagSet("sesstat", flag.ContinueOnError)

	// Disable default output to prevent duplicate messages
	fs.SetOutput(io.Discard)

	// Parse global flags
	globalFlags := config.ParseGlobalFlags(fs)

	// Query-specific filters
	var sids, statNames string

	fs.StringVar(&sids, "sid", "", "Session ID filter (comma-separated, e.g., 40,50,90)")
	fs.StringVar(&sids, "S", "", "Session ID filter (short)")
	fs.StringVar(&statNames, "stat", "", "Statistic name filter (comma-separated, supports % wildcard)")
	fs.StringVar(&statNames, "n", "", "Statistic name filter (short)")

	if err := fs.Parse(os.Args[2:]); err != nil {
		// Print error message for non-help errors
		if err != flag.ErrHelp {
			fmt.Fprintf(os.Stderr, "Error: %v\n\n", err)
		}
		config.PrintSesstatUsage()
		os.Exit(1)
	}

	// Build config
	cfg := config.DefaultConfig()
	if globalFlags.ConfigFile != "" {
		// Load from file if specified
		loadedCfg, err := config.LoadConfig()
		if err == nil {
			cfg = loadedCfg
		}
	}

	// Apply global flags to config
	globalFlags.ApplyToConfig(cfg)

	// Validate
	if err := cfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "Configuration error: %v\n", err)
		os.Exit(1)
	}

	// Create connector
	conn, err := connector.NewConnector(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating connector: %v\n", err)
		os.Exit(1)
	}

	// Connect
	ctx := context.Background()
	if err := conn.Connect(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Error connecting to database: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	// Prepare query config
	instIDs := fmt.Sprintf("%d", globalFlags.InstanceID)
	if globalFlags.InstanceID == 0 {
		instIDs = "" // Empty means all instances
	}

	qc := &subcommand.QueryConfig{
		ViewName:      "gv$sesstat a, v$statname b",
		ValueColumns:  []string{"a.value"},
		FilterColumn:  "b.name",
		ExcludeFilter: "a.statistic# = b.statistic#",
		NoAlias:       true, // ViewName already contains aliases
	}

	// Display function for sesstat
	displayFunc := func(deltas []subcommand.Record, topN int, instIDs, sids, names string, sample, totalSamples int) {
		subcommand.DisplayResults(deltas, topN, instIDs, sids, names, sample, totalSamples, "Session Statistics", false)
	}

	// Run subcommand
	subcommand.RunSubcommand(ctx, conn, qc, globalFlags.Interval, globalFlags.Count, globalFlags.TopN, instIDs, sids, statNames, displayFunc)
}
