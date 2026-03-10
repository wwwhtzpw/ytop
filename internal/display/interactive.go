package display

import (
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/models"
	"github.com/yihan/ytop/internal/scripts"
)

// InteractiveDisplay handles interactive terminal display
type InteractiveDisplay struct {
	*Display
	sessionList []models.SessionDetail
	conn        connector.Connector
}

// NewInteractiveDisplay creates a new interactive display
func NewInteractiveDisplay(d *Display, conn connector.Connector) *InteractiveDisplay {
	return &InteractiveDisplay{
		Display: d,
		conn:    conn,
	}
}

// RenderInteractive renders the snapshot with selection highlight
func (d *InteractiveDisplay) RenderInteractive(snapshot *models.Snapshot) {
	d.iteration++
	d.sessionList = snapshot.SessionDetails

	// Clear screen and move cursor to top-left
	fmt.Print("\033[2J\033[H")

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

	// Footer with instructions
	d.renderInteractiveFooter(&output)

	// In raw terminal mode, we need to replace \n with \r\n for proper line breaks
	outputStr := strings.ReplaceAll(output.String(), "\n", "\r\n")

	// Print to terminal
	fmt.Print(outputStr)

	// Write to file if configured (use original output without \r)
	if d.outputFile != nil {
		d.outputFile.WriteString(output.String())
		d.outputFile.WriteString("\n" + strings.Repeat("=", 120) + "\n\n")
	}
}

// renderInteractiveFooter renders footer with keyboard instructions
func (d *InteractiveDisplay) renderInteractiveFooter(out *strings.Builder) {
	out.WriteString(strings.Repeat("-", 120))
	out.WriteString("\n")
	out.WriteString("Press: [a] Ad-hoc SQL | [s] Script/Cmd | [r] Read | [c] Copy | [f] Find | [h] Help | [q/ESC] Quit\n")
}

// ShowHelp displays help information
func (d *InteractiveDisplay) ShowHelp() string {
	var help strings.Builder
	help.WriteString("\n")
	help.WriteString(strings.Repeat("=", 80))
	help.WriteString("\n")
	help.WriteString("                    YTOP Interactive Mode Help\n")
	help.WriteString(strings.Repeat("=", 80))
	help.WriteString("\n\n")
	help.WriteString("Keyboard Commands:\n")
	help.WriteString("  ↑ / ↓       - Navigate up/down through active sessions\n")
	help.WriteString("  p / P       - View SQL plan for selected session's SQL ID\n")
	help.WriteString("  a / A       - Execute ad-hoc SQL statement\n")
	help.WriteString("  s / S       - Execute custom SQL script or OS command\n")
	help.WriteString("  r / R       - Read/view script content\n")
	help.WriteString("  c / C       - Copy script to server/local directory\n")
	help.WriteString("  f / F       - Find/search available scripts\n")
	help.WriteString("  h / H       - Show this help\n")
	help.WriteString("  q / Q / ESC - Quit ytop\n")
	help.WriteString("\n")
	help.WriteString("Copy Script (c key):\n")
	help.WriteString("  - Enter script filename and optional destination path\n")
	help.WriteString("  - Format: <scriptname> [destpath]\n")
	help.WriteString("  - Example: we.sql /tmp (copies to /tmp/we.sql)\n")
	help.WriteString("  - Example: we.sql (defaults to /tmp/we.sql)\n")
	help.WriteString("  - .sql files are searched in scripts/sql/ directory\n")
	help.WriteString("  - Other files are searched in scripts/os/ directory\n")
	help.WriteString("  - SSH mode: copies to remote server (-h specified)\n")
	help.WriteString("  - Local mode: copies to local filesystem (no -h)\n")
	help.WriteString("  - Verifies file after copy (checks existence and size)\n")
	help.WriteString("  - Press ESC to cancel input\n")
	help.WriteString("\n")
	help.WriteString("Find Scripts (f key):\n")
	help.WriteString("  - Enter regex pattern to search for scripts\n")
	help.WriteString("  - Use .* to list all available scripts\n")
	help.WriteString("  - Shows script type (sql/os), filename, and description\n")
	help.WriteString("  - Description is read from second line of script file\n")
	help.WriteString("  - Press ESC to cancel search\n")
	help.WriteString("\n")
	help.WriteString("Ad-hoc SQL (a key):\n")
	help.WriteString("  - Enter any SQL statement directly\n")
	help.WriteString("  - Executed immediately via yasql -c\n")
	help.WriteString("  - Special characters automatically escaped\n")
	help.WriteString("  - Press ESC to cancel input\n")
	help.WriteString("\n")
	help.WriteString("Execute Script/Command (s key):\n")
	help.WriteString("  - SQL scripts:  Enter filename ending with .sql (e.g., we.sql)\n")
	help.WriteString("                  Simple name: searches in embedded scripts/sql/\n")
	help.WriteString("                  Absolute path: /path/to/script.sql (Linux/Mac)\n")
	help.WriteString("                  Absolute path: D:\\path\\to\\script.sql (Windows)\n")
	help.WriteString("                  Relative path: ./script.sql or ../script.sql\n")
	help.WriteString("                  Scripts with & or && variables will prompt for input\n")
	help.WriteString("  - OS commands:  Enter any shell command (e.g., iostat 1 2)\n")
	help.WriteString("                  Or embedded OS scripts from scripts/os/\n")
	help.WriteString("  - Press ESC to cancel input\n")
	help.WriteString("\n")
	help.WriteString("Connection Modes:\n")
	help.WriteString("  - Local:    yasql executed locally\n")
	help.WriteString("  - SSH:      Commands executed on remote host via SSH\n")
	help.WriteString("              Scripts uploaded to /tmp/ for '/ as sysdba' auth\n")
	help.WriteString("\n")
	help.WriteString("Output:\n")
	help.WriteString("  - SQL plan output saved to: sql_<sqlid>.txt\n")
	help.WriteString("  - Command output saved to: output_<command>.txt\n")
	help.WriteString("  - Temporary files deleted unless --debug mode enabled\n")
	help.WriteString("\n")
	help.WriteString(strings.Repeat("=", 80))
	help.WriteString("\n")
	return help.String()
}

// GetSelectedSQLID returns the SQL ID of the currently selected session
func (d *InteractiveDisplay) GetSelectedSQLID() string {
	if len(d.sessionList) > 0 {
		sqlID := d.sessionList[0].SqlID
		// Remove command prefix (e.g., "SEL.abc123" -> "abc123")
		parts := strings.Split(sqlID, ".")
		if len(parts) > 1 {
			return parts[1]
		}
		return sqlID
	}
	return ""
}

// ExecuteSQLPlan executes the SQL plan script for the selected SQL ID
func (d *InteractiveDisplay) ExecuteSQLPlan(ctx context.Context) error {
	sqlID := d.GetSelectedSQLID()
	if sqlID == "" {
		return fmt.Errorf("no SQL ID available for selected session")
	}

	// Get SQL script
	script, err := scripts.GetSQLScript("sql.sql")
	if err != nil {
		return fmt.Errorf("failed to load SQL script: %w", err)
	}

	// Replace &&sqlid with actual SQL ID
	script = scripts.ReplaceSQLID(script, sqlID)

	// Execute SQL script
	output, err := d.executeSQLScript(ctx, script)
	if err != nil {
		return fmt.Errorf("failed to execute SQL script: %w", err)
	}

	// Write output to file
	if err := scripts.WriteSQLOutput(sqlID, output); err != nil {
		return fmt.Errorf("failed to write SQL output: %w", err)
	}

	// Show success message
	fmt.Printf("\n\nSQL plan saved to: sql_%s.txt\nPress any key to continue...", sqlID)

	// Wait for key press
	exec.Command("bash", "-c", "read -n 1").Run()

	return nil
}

// executeSQLScript executes a SQL script via connector
func (d *InteractiveDisplay) executeSQLScript(ctx context.Context, script string) (string, error) {
	// Split script into individual statements
	statements := strings.Split(script, ";")

	var output strings.Builder

	for _, stmt := range statements {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}

		// Skip comments and prompts
		if strings.HasPrefix(stmt, "--") || strings.HasPrefix(stmt, "prompt") ||
		   strings.HasPrefix(stmt, "set ") {
			continue
		}

		// Execute statement
		rows, err := d.conn.ExecuteQuery(ctx, stmt)
		if err != nil {
			output.WriteString(fmt.Sprintf("Error executing statement: %v\n", err))
			continue
		}

		// Format output
		for _, row := range rows {
			output.WriteString(strings.Join(row, " | "))
			output.WriteString("\n")
		}
		output.WriteString("\n")
	}

	return output.String(), nil
}
