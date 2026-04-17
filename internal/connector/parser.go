package connector

import (
	"bufio"
	"fmt"
	"regexp"
	"strings"
)

// yashanErrorPattern matches YashanDB error codes like YAS-04209
var yashanErrorPattern = regexp.MustCompile(`YAS-\d{5}`)

// checkYashanError checks if output contains YashanDB error codes
func checkYashanError(output string) error {
	if yashanErrorPattern.MatchString(output) {
		// Extract error lines
		var errorLines []string
		scanner := bufio.NewScanner(strings.NewReader(output))
		for scanner.Scan() {
			line := scanner.Text()
			if yashanErrorPattern.MatchString(line) {
				errorLines = append(errorLines, line)
			}
		}
		if len(errorLines) > 0 {
			return fmt.Errorf("YashanDB error detected:\n%s", strings.Join(errorLines, "\n"))
		}
	}
	return nil
}

// parseYasqlOutput parses yasql output into rows
// YashanDB yasql outputs data in fixed-width columns with headers
func parseYasqlOutput(output string) ([][]string, error) {
	// Check for YashanDB errors first
	if err := checkYashanError(output); err != nil {
		return nil, err
	}

	var rows [][]string
	scanner := bufio.NewScanner(strings.NewReader(output))

	var separatorLine string
	var dataStarted bool

	for scanner.Scan() {
		line := scanner.Text()

		// Skip empty lines
		if strings.TrimSpace(line) == "" {
			continue
		}

		// Skip "X rows fetched" lines
		if strings.Contains(line, "rows fetched") || strings.Contains(line, "row fetched") {
			continue
		}

		// Skip "Disconnected from" lines
		if strings.Contains(line, "Disconnected from") {
			continue
		}

		// Detect separator line (dashes)
		if strings.Contains(line, "---") && !dataStarted {
			separatorLine = line
			dataStarted = true
			continue
		}

		// If we haven't found separator yet, skip (likely header)
		if !dataStarted {
			continue
		}

		// Parse data line using separator positions
		if separatorLine != "" {
			fields := parseFixedWidthLine(line, separatorLine)
			if len(fields) > 0 {
				rows = append(rows, fields)
			}
		} else {
			// Fallback to whitespace splitting
			fields := strings.Fields(line)
			if len(fields) > 0 {
				rows = append(rows, fields)
			}
		}
	}

	return rows, nil
}

// parseFixedWidthLine parses a line based on separator positions
func parseFixedWidthLine(line, separator string) []string {
	var fields []string
	var start int
	inField := false

	// Find column boundaries from separator line
	for i, ch := range separator {
		if ch == '-' && !inField {
			start = i
			inField = true
		} else if ch == ' ' && inField {
			// End of field
			if start < len(line) {
				end := min(i, len(line))
				field := strings.TrimSpace(line[start:end])
				if field != "" {
					fields = append(fields, field)
				}
			}
			inField = false
		}
	}

	// Handle last field
	if inField && start < len(line) {
		field := strings.TrimSpace(line[start:])
		if field != "" {
			fields = append(fields, field)
		}
	}

	return fields
}

// ParseYasqlOutputWithHeader parses yasql output and returns header + data rows
// This is similar to parseYasqlOutput but also returns the header row
func ParseYasqlOutputWithHeader(output string) (header []string, rows [][]string, err error) {
	// Check for YashanDB errors first
	if err := checkYashanError(output); err != nil {
		return nil, nil, err
	}

	scanner := bufio.NewScanner(strings.NewReader(output))

	var separatorLine string
	var headerFound bool
	var dataStarted bool

	for scanner.Scan() {
		line := scanner.Text()

		// Skip empty lines
		if strings.TrimSpace(line) == "" {
			continue
		}

		// Skip "X rows fetched" lines
		if strings.Contains(line, "rows fetched") || strings.Contains(line, "row fetched") {
			continue
		}

		// Skip "Disconnected from" lines
		if strings.Contains(line, "Disconnected from") {
			continue
		}

		// Detect separator line (dashes)
		if strings.Contains(line, "---") && !dataStarted {
			separatorLine = line
			dataStarted = true
			continue
		}

		// If we haven't found separator yet, this is header
		if !dataStarted {
			headerLine := strings.Fields(line)
			if len(headerLine) > 0 {
				header = headerLine
				headerFound = true
			}
			continue
		}

		// Parse data line using separator positions
		if separatorLine != "" {
			fields := parseFixedWidthLine(line, separatorLine)
			if len(fields) > 0 {
				rows = append(rows, fields)
			}
		} else {
			// Fallback to whitespace splitting
			fields := strings.Fields(line)
			if len(fields) > 0 {
				rows = append(rows, fields)
			}
		}
	}

	// If no header found but we have data, generate default column names
	if !headerFound && len(rows) > 0 {
		header = make([]string, len(rows[0]))
		for i := range header {
			header[i] = fmt.Sprintf("COL%d", i+1)
		}
	}

	return header, rows, nil
}
