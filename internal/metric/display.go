package metric

import (
	"fmt"
	"strings"
)

// Display formats and renders metric results
type Display struct {
	sqlFile string
}

// NewDisplay creates a new display
func NewDisplay(sqlFile string) *Display {
	return &Display{
		sqlFile: sqlFile,
	}
}

// Render formats the result as a table string
func (d *Display) Render(result *Result, iteration, maxIterations int) string {
	if result == nil {
		return ""
	}

	var sb strings.Builder

	// Build all columns to display (already includes group + numeric + string columns)
	displayCols := result.Columns

	// Calculate column widths
	widths := make(map[string]int)
	for _, col := range displayCols {
		widths[col] = len(col)
	}

	// Check data widths
	for _, gd := range result.PerGroup {
		for _, col := range displayCols {
			var valStr string
			if col == result.GroupKey {
				valStr = gd.GroupKey
			} else if val, ok := gd.NumericVals[col]; ok {
				valStr = FormatFloat(val)
			} else if sval, ok := gd.StringVals[col]; ok {
				valStr = sval
			}
			if len(valStr) > widths[col] {
				widths[col] = len(valStr)
			}
		}
	}

	// Check AVG row widths (only for numeric columns)
	for _, col := range displayCols {
		if col != result.GroupKey {
			if val, ok := result.Aggregated[col]; ok {
				valStr := FormatFloat(val)
				if len(valStr) > widths[col] {
					widths[col] = len(valStr)
				}
			}
		}
	}

	// Ensure minimum width for group column
	if result.GroupKey != "" && widths[result.GroupKey] < 5 {
		widths[result.GroupKey] = 5
	}

	// Print header
	headerParts := make([]string, 0, len(displayCols))
	for _, col := range displayCols {
		headerParts = append(headerParts, fmt.Sprintf("%*s", widths[col], col))
	}
	sb.WriteString(strings.Join(headerParts, " | "))
	sb.WriteString("\n")

	// Print separator
	sepParts := make([]string, 0, len(displayCols))
	for _, col := range displayCols {
		sepParts = append(sepParts, strings.Repeat("-", widths[col]))
	}
	sb.WriteString(strings.Join(sepParts, "-|-"))
	sb.WriteString("\n")

	// Print data rows
	for _, gd := range result.PerGroup {
		rowParts := make([]string, 0, len(displayCols))
		for _, col := range displayCols {
			var valStr string
			if col == result.GroupKey {
				valStr = fmt.Sprintf("%*s", widths[col], gd.GroupKey)
			} else if val, ok := gd.NumericVals[col]; ok {
				valStr = fmt.Sprintf("%*s", widths[col], FormatFloat(val))
			} else if sval, ok := gd.StringVals[col]; ok {
				valStr = fmt.Sprintf("%*s", widths[col], sval)
			}
			rowParts = append(rowParts, valStr)
		}
		sb.WriteString(strings.Join(rowParts, " | "))
		sb.WriteString("\n")
	}

	// Print separator before AVG (only if multiple groups)
	if len(result.PerGroup) > 1 {
		sb.WriteString(strings.Join(sepParts, "-|-"))
		sb.WriteString("\n")

		// Print AVG row
		avgParts := make([]string, 0, len(displayCols))
		for _, col := range displayCols {
			var valStr string
			if col == result.GroupKey {
				valStr = fmt.Sprintf("%*s", widths[col], "AVG")
			} else if val, ok := result.Aggregated[col]; ok {
				valStr = fmt.Sprintf("%*s", widths[col], FormatFloat(val))
			} else {
				valStr = fmt.Sprintf("%*s", widths[col], "-")
			}
			avgParts = append(avgParts, valStr)
		}
		sb.WriteString(strings.Join(avgParts, " | "))
		sb.WriteString("\n")
	}

	return sb.String()
}
