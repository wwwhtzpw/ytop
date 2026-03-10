package utils

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// ParseCommaSeparatedInts parses comma-separated integers and validates them
func ParseCommaSeparatedInts(input string) ([]int, error) {
	if input == "" {
		return nil, nil
	}

	parts := strings.Split(input, ",")
	var result []int

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}

		num, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid number: %s", part)
		}

		result = append(result, num)
	}

	return result, nil
}

// ParseCommaSeparatedStrings parses comma-separated strings and trims them
func ParseCommaSeparatedStrings(input string) []string {
	if input == "" {
		return nil
	}

	parts := strings.Split(input, ",")
	var result []string

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}

	return result
}

// BuildInClause builds SQL IN clause with integer values
func BuildInClause(columnName string, values []int) string {
	if len(values) == 0 {
		return ""
	}

	strValues := make([]string, len(values))
	for i, v := range values {
		strValues[i] = strconv.Itoa(v)
	}

	return fmt.Sprintf("%s IN (%s)", columnName, strings.Join(strValues, ","))
}

// BuildLikeClause builds SQL LIKE clause with OR conditions
func BuildLikeClause(columnName string, patterns []string) string {
	if len(patterns) == 0 {
		return ""
	}

	var conditions []string
	for _, pattern := range patterns {
		// Escape single quotes in pattern
		pattern = strings.ReplaceAll(pattern, "'", "''")
		conditions = append(conditions, fmt.Sprintf("%s LIKE '%s'", columnName, pattern))
	}

	return "(" + strings.Join(conditions, " OR ") + ")"
}

// ShellEscape escapes a string for safe use in shell commands
func ShellEscape(s string) string {
	// Replace single quotes with '\'' (end quote, escaped quote, start quote)
	escaped := strings.ReplaceAll(s, "'", "'\\''")
	return "'" + escaped + "'"
}

// ValidateSQLIdentifier validates that a string is a safe SQL identifier
func ValidateSQLIdentifier(s string) bool {
	// Allow alphanumeric, underscore, and common SQL wildcards
	match, _ := regexp.MatchString(`^[\w%]+$`, s)
	return match
}

// Contains checks if a string is in a slice
func Contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}
