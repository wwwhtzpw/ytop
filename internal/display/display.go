package display

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/models"
	"golang.org/x/term"
)

// Display handles terminal output
type Display struct {
	cfg        *config.Config
	outputFile *os.File
	iteration  int
	isTerminal bool
}

// NewDisplay creates a new display
func NewDisplay(cfg *config.Config) (*Display, error) {
	isTerminal := term.IsTerminal(int(os.Stdout.Fd()))

	d := &Display{
		cfg:        cfg,
		isTerminal: isTerminal,
	}

	// Disable color if not outputting to a terminal
	if !isTerminal {
		d.cfg.ColorEnabled = false
	}

	// Open output file if specified
	if cfg.OutputFile != "" {
		f, err := os.OpenFile(cfg.OutputFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			return nil, fmt.Errorf("failed to open output file: %w", err)
		}
		d.outputFile = f
	}

	return d, nil
}

// Render renders the snapshot to terminal and optionally to file
func (d *Display) Render(snapshot *models.Snapshot) {
	d.iteration++

	// Clear screen only if output is to a terminal
	if d.isTerminal {
		fmt.Print("\033[2J\033[H")
	}

	var output strings.Builder

	// Header
	d.renderHeader(&output, snapshot.Timestamp)

	// v$sysstat metrics
	d.renderSysStats(&output, snapshot.SysStats)

	// v$system_event TOP N
	d.renderSystemEvents(&output, snapshot.SystemEvents)

	// Session metrics TOP N
	d.renderSessionMetrics(&output, snapshot.SessionMetrics)

	// Session details
	d.renderSessionDetails(&output, snapshot.SessionDetails)

	// Footer
	d.renderFooter(&output)

	// Print to terminal
	fmt.Print(output.String())

	// Write to file if configured
	if d.outputFile != nil {
		d.outputFile.WriteString(output.String())
		d.outputFile.WriteString("\n" + strings.Repeat("=", 120) + "\n\n")
	}
}

// renderHeader renders the header section
func (d *Display) renderHeader(out *strings.Builder, timestamp time.Time) {
	// Only show timestamp when output file is specified
	if d.cfg.OutputFile != "" {
		out.WriteString(fmt.Sprintf("Time: %s", timestamp.Format("2006-01-02 15:04:05")))
		if d.cfg.Count > 0 {
			out.WriteString(fmt.Sprintf(" | Iteration: %d / %d", d.iteration, d.cfg.Count))
		}
		out.WriteString("\n")
		out.WriteString(strings.Repeat("-", 120))
		out.WriteString("\n\n")
	}
}

// renderSysStats renders v$sysstat metrics in a single row format with aligned columns
// Supports multi-instance display
func (d *Display) renderSysStats(out *strings.Builder, metrics []models.SysStatMetric) {
	out.WriteString(d.colorize("v$SYSSTAT Metrics (Per Second)\n", "yellow"))
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	if len(metrics) == 0 {
		out.WriteString("No metrics available\n\n")
		return
	}

	colWidth := 6 // Width for each column

	// Metric name mapping for better readability (max 6 chars)
	nameMap := map[string]string{
		"BLOCK CHANGES":      "BLKCHG",
		"BUFFER CR GETS":     "CRGETS",
		"BUFFER GETS":        "GETS",
		"COMMITS":            "COMMIT",
		"CPU TIME":           "CPUTIM",
		"DB TIME":            "DBTIM",
		"DISK READS":         "PHYRD",
		"DISK WRITES":        "PHYWR",
		"EXECUTE COUNT":      "EXEC",
		"INSERT COUNT":       "INSERT",
		"LOGONS TOTAL":       "LOGONS",
		"PARSE COUNT (HARD)": "HRDPRS",
		"QUERY COUNT":        "QUERY",
		"REDO SIZE":          "REDO",
	}

	// Check if we have any delta values
	hasNonZero := false
	for _, m := range metrics {
		if m.DeltaPerSec > 0.01 {
			hasNonZero = true
			break
		}
	}

	// First iteration (no delta), don't display
	if !hasNonZero {
		out.WriteString("Collecting baseline data...\n\n")
		return
	}

	// Group metrics by instance
	instMetrics := make(map[int][]models.SysStatMetric)
	for _, m := range metrics {
		instMetrics[m.InstID] = append(instMetrics[m.InstID], m)
	}

	// Get sorted instance IDs
	var instIDs []int
	for instID := range instMetrics {
		instIDs = append(instIDs, instID)
	}
	sort.Ints(instIDs)

	// Header row - I + metric names (right-aligned)
	out.WriteString(d.colorize(fmt.Sprintf("%2s", "I"), "bold"))
	out.WriteString(" ")

	// Use first instance's metrics to get metric names in order
	firstInstMetrics := instMetrics[instIDs[0]]
	for i, m := range firstInstMetrics {
		shortName := nameMap[m.Name]
		if shortName == "" {
			shortName = d.truncate(m.Name, colWidth)
		}
		if i > 0 {
			out.WriteString(" ")
		}
		out.WriteString(d.colorize(fmt.Sprintf("%*s", colWidth, shortName), "bold"))
	}
	out.WriteString("\n")

	// Data rows - one per instance
	for _, instID := range instIDs {
		out.WriteString(fmt.Sprintf("%2d", instID))
		out.WriteString(" ")

		for i, m := range instMetrics[instID] {
			if i > 0 {
				out.WriteString(" ")
			}

			var valueStr string
			if m.DeltaPerSec > 0.01 {
				// Show delta per second (without /s)
				valueStr = d.formatNumber(m.DeltaPerSec)
			} else {
				// Zero or very small delta
				valueStr = "0"
			}
			out.WriteString(fmt.Sprintf("%*s", colWidth, valueStr))
		}
		out.WriteString("\n")
	}

	out.WriteString("\n")
}

// renderSystemEvents renders v$system_event TOP N
func (d *Display) renderSystemEvents(out *strings.Builder, events []models.SystemEvent) {
	out.WriteString(d.colorize(fmt.Sprintf("v$SYSTEM_EVENT TOP %d (By Wait Time)\n", d.cfg.EventTopN), "yellow"))
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	if len(events) == 0 {
		out.WriteString("Collecting baseline data...\n\n")
		return
	}

	// Column widths
	instWidth := 2
	eventWidth := 40
	waitsWidth := 15
	timeWidth := 15
	avgWidth := 15
	pctWidth := 10

	// Header (right-aligned for numbers)
	out.WriteString(d.colorize(fmt.Sprintf("%*s", instWidth, "I"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", eventWidth, "Event Name"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%*s", waitsWidth, "Total Waits"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%*s", timeWidth, "Time Wait(s)"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%*s", avgWidth, "Avg Wait(ms)"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%*s", pctWidth, "Pct%"), "bold"))
	out.WriteString("\n")
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	// Data rows (right-aligned for numbers)
	for _, e := range events {
		avgWaitMs := e.AvgWaitTime * 1000
		out.WriteString(fmt.Sprintf("%*d", instWidth, e.InstID))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", eventWidth, d.truncate(e.EventName, eventWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%*s", waitsWidth, d.formatNumber(float64(e.TotalWaits))))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%*s", timeWidth, d.formatNumber(e.TimeWaited)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%*s", avgWidth, d.formatNumber(avgWaitMs)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%*.2f%%", pctWidth-1, e.Percentage))
		out.WriteString("\n")
	}

	out.WriteString("\n")
}

// renderSessionMetrics renders session metrics TOP N
func (d *Display) renderSessionMetrics(out *strings.Builder, metrics []models.SessionMetric) {
	out.WriteString(d.colorize(fmt.Sprintf("Session Metrics TOP %d (Sorted by %s)\n", d.cfg.SessionTopN, d.cfg.SessionSortBy), "yellow"))
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	if len(metrics) == 0 {
		out.WriteString("Collecting baseline data...\n\n")
		return
	}

	// Column width
	instWidth := 2
	colWidth := 6
	sidTidWidth := 18
	usernameWidth := 12
	sqlIDWidth := 15
	programWidth := 20

	// Metric names in order (matching v$SYSSTAT)
	metricNames := []string{
		"BLOCK CHANGES",
		"BUFFER CR GETS",
		"BUFFER GETS",
		"COMMITS",
		"CPU TIME",
		"DB TIME",
		"DISK READS",
		"DISK WRITES",
		"EXECUTE COUNT",
		"INSERT COUNT",
		"LOGONS TOTAL",
		"PARSE COUNT (HARD)",
		"QUERY COUNT",
		"REDO SIZE",
	}

	// Short names mapping (same as v$SYSSTAT, max 6 chars)
	nameMap := map[string]string{
		"BLOCK CHANGES":      "BLKCHG",
		"BUFFER CR GETS":     "CRGETS",
		"BUFFER GETS":        "GETS",
		"COMMITS":            "COMMIT",
		"CPU TIME":           "CPUTIM",
		"DB TIME":            "DBTIM",
		"DISK READS":         "PHYRD",
		"DISK WRITES":        "PHYWR",
		"EXECUTE COUNT":      "EXEC",
		"INSERT COUNT":       "INSERT",
		"LOGONS TOTAL":       "LOGONS",
		"PARSE COUNT (HARD)": "HRDPRS",
		"QUERY COUNT":        "QUERY",
		"REDO SIZE":          "REDO",
	}

	// Header row: I, SID.Serial.TID, Username, SQL_ID, Program, Metrics
	out.WriteString(d.colorize(fmt.Sprintf("%*s", instWidth, "I"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", sidTidWidth, "SID.Serial.TID"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", usernameWidth, "Username"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", sqlIDWidth, "SQL_ID"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", programWidth, "Program"), "bold"))

	// Header row: Metric names
	for _, metricName := range metricNames {
		shortName := nameMap[metricName]
		out.WriteString(" ")
		out.WriteString(d.colorize(fmt.Sprintf("%*s", colWidth, shortName), "bold"))
	}
	out.WriteString("\n")
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	// Data rows
	for _, m := range metrics {
		out.WriteString(fmt.Sprintf("%*d", instWidth, m.InstID))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", sidTidWidth, d.truncate(m.SidTid, sidTidWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", usernameWidth, d.truncate(m.Username, usernameWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", sqlIDWidth, d.truncate(m.SqlID, sqlIDWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", programWidth, d.truncate(m.Program, programWidth)))

		for _, metricName := range metricNames {
			out.WriteString(" ")
			value := m.Metrics[metricName]
			out.WriteString(fmt.Sprintf("%*s", colWidth, d.formatNumber(value)))
		}
		out.WriteString("\n")
	}

	out.WriteString("\n")
}

// renderSessionDetails renders session details
func (d *Display) renderSessionDetails(out *strings.Builder, details []models.SessionDetail) {
	out.WriteString(d.colorize(fmt.Sprintf("Active Sessions TOP %d (By Execution Time)\n", d.cfg.SessionDetailTopN), "yellow"))
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	if len(details) == 0 {
		out.WriteString("No active sessions found\n\n")
		return
	}

	// Column widths
	instWidth := 2
	sidWidth := 30
	eventWidth := 20
	usernameWidth := 15
	sqlIDWidth := 20
	execTimeWidth := 10
	programWidth := 20
	clientWidth := 20

	// Header
	out.WriteString(d.colorize(fmt.Sprintf("%*s", instWidth, "I"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", sidWidth, "SID.Serial"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", eventWidth, "Event"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", usernameWidth, "Username"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", sqlIDWidth, "SQL ID"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", execTimeWidth, "Exec Time"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", programWidth, "Program"), "bold"))
	out.WriteString(" ")
	out.WriteString(d.colorize(fmt.Sprintf("%-*s", clientWidth, "Client"), "bold"))
	out.WriteString("\n")
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")

	// Data rows
	for _, s := range details {
		out.WriteString(fmt.Sprintf("%*d", instWidth, s.InstID))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", sidWidth, d.truncate(s.SidTid, sidWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", eventWidth, d.truncate(s.Event, eventWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", usernameWidth, d.truncate(s.Username, usernameWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", sqlIDWidth, d.truncate(s.SqlID, sqlIDWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", execTimeWidth, s.ExecTime))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", programWidth, d.truncate(s.Program, programWidth)))
		out.WriteString(" ")
		out.WriteString(fmt.Sprintf("%-*s", clientWidth, d.truncate(s.Client, clientWidth)))
		out.WriteString("\n")
	}

	out.WriteString("\n")
}

// renderFooter renders the footer section
func (d *Display) renderFooter(out *strings.Builder) {
	out.WriteString(strings.Repeat(d.colorize("-", "cyan"), 120))
	out.WriteString("\n")
	out.WriteString(d.colorize("Press Ctrl+C to exit", "cyan"))
	if d.cfg.OutputFile != "" {
		out.WriteString(d.colorize(fmt.Sprintf(" | Output: %s", d.cfg.OutputFile), "cyan"))
	}
	out.WriteString("\n")
}

// colorize adds ANSI color codes if color is enabled
func (d *Display) colorize(text, color string) string {
	if !d.cfg.ColorEnabled {
		return text
	}

	colors := map[string]string{
		"red":     "\033[31m",
		"green":   "\033[32m",
		"yellow":  "\033[33m",
		"blue":    "\033[34m",
		"magenta": "\033[35m",
		"cyan":    "\033[36m",
		"white":   "\033[37m",
		"bold":    "\033[1m",
		"reset":   "\033[0m",
	}

	if code, ok := colors[color]; ok {
		return code + text + colors["reset"]
	}

	return text
}

// center centers text in a given width
func (d *Display) center(text string, width int) string {
	if len(text) >= width {
		return text
	}
	padding := (width - len(text)) / 2
	return strings.Repeat(" ", padding) + text
}

// truncate truncates text to specified length
func (d *Display) truncate(text string, length int) string {
	if len(text) <= length {
		return text
	}
	return text[:length-3] + "..."
}

// formatNumber formats a number with K/M/G suffixes
func (d *Display) formatNumber(value float64) string {
	absValue := value
	if absValue < 0 {
		absValue = -absValue
	}

	var result string
	if absValue >= 1000000000 {
		result = fmt.Sprintf("%.1fG", value/1000000000)
	} else if absValue >= 1000000 {
		result = fmt.Sprintf("%.1fM", value/1000000)
	} else if absValue >= 1000 {
		result = fmt.Sprintf("%.1fK", value/1000)
	} else if absValue >= 1 {
		result = fmt.Sprintf("%.0f", value)
	} else if absValue > 0 {
		result = fmt.Sprintf("%.2f", value)
	} else {
		result = "0"
	}

	return result
}

// Close closes the display and any open files
func (d *Display) Close() error {
	if d.outputFile != nil {
		return d.outputFile.Close()
	}
	return nil
}
