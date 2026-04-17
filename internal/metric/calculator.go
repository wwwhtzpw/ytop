package metric

import (
	"fmt"
	"strconv"
	"strings"
)

// Calculator calculates deltas and per-second rates
type Calculator struct {
	previous   *Snapshot
	columnInfo *ColumnInfo
}

// NewCalculator creates a new calculator
func NewCalculator(columnInfo *ColumnInfo) *Calculator {
	return &Calculator{
		columnInfo: columnInfo,
	}
}

// Result represents the calculated metric result
type Result struct {
	SQLFile     string
	IntervalSec float64
	Columns     []string // All display columns (group + value + string)
	GroupKey    string
	// PerGroup contains delta/per-second values for each group
	PerGroup []GroupData
	// Aggregated contains average values across all groups (only for numeric columns)
	Aggregated map[string]float64
}

// GroupData represents metrics for a single group
type GroupData struct {
	GroupKey    string              // e.g., "1", "2" or "ALL"
	NumericVals map[string]float64  // column -> per_sec value (for numeric columns)
	StringVals  map[string]string   // column -> current value (for string/time columns)
}

// Calculate computes deltas and per-second rates
func (c *Calculator) Calculate(current *Snapshot) *Result {
	if c.previous == nil {
		c.previous = current
		return nil
	}

	// Calculate actual time interval
	intervalSec := current.Timestamp.Sub(c.previous.Timestamp).Seconds()
	if intervalSec <= 0 {
		intervalSec = 1
	}

	// Build all columns list
	var allColumns []string
	if c.columnInfo.GroupColumn != "" {
		allColumns = append(allColumns, c.columnInfo.GroupColumn)
	}
	allColumns = append(allColumns, c.columnInfo.ValueColumns...)
	allColumns = append(allColumns, c.columnInfo.StringColumns...)

	result := &Result{
		SQLFile:     "",
		IntervalSec: intervalSec,
		Columns:     allColumns,
		GroupKey:    c.columnInfo.GroupColumn,
		PerGroup:    make([]GroupData, 0),
		Aggregated:  make(map[string]float64),
	}

	// Group current and previous rows by group key
	prevMap := c.groupByColumn(c.previous)
	currMap := c.groupByColumn(current)

	// Calculate per-group deltas
	for groupKey, currRow := range currMap {
		prevRow, exists := prevMap[groupKey]
		if !exists {
			continue
		}

		// Calculate numeric deltas
		numericVals := make(map[string]float64)
		for _, col := range c.columnInfo.ValueColumns {
			currVal := toFloat(currRow[col])
			prevVal := toFloat(prevRow[col])
			delta := currVal - prevVal
			numericVals[col] = delta / intervalSec
		}

		// Get current string values (no delta, just current value)
		stringVals := make(map[string]string)
		for _, col := range c.columnInfo.StringColumns {
			stringVals[col] = toString(currRow[col])
		}

		result.PerGroup = append(result.PerGroup, GroupData{
			GroupKey:    groupKey,
			NumericVals: numericVals,
			StringVals:  stringVals,
		})
	}

	// Calculate aggregated averages (only for numeric columns)
	for _, col := range c.columnInfo.ValueColumns {
		var sum float64
		count := 0
		for _, gd := range result.PerGroup {
			sum += gd.NumericVals[col]
			count++
		}
		if count > 0 {
			result.Aggregated[col] = sum / float64(count)
		}
	}

	c.previous = current
	return result
}

// groupByColumn groups rows by the group column
func (c *Calculator) groupByColumn(snapshot *Snapshot) map[string]map[string]interface{} {
	result := make(map[string]map[string]interface{})
	for _, row := range snapshot.Rows {
		key := fmt.Sprintf("%v", row[c.columnInfo.GroupColumn])
		result[key] = row
	}
	return result
}

// toFloat converts interface{} to float64
func toFloat(v interface{}) float64 {
	switch val := v.(type) {
	case float64:
		return val
	case float32:
		return float64(val)
	case int:
		return float64(val)
	case int64:
		return float64(val)
	case int32:
		return float64(val)
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(val), 64)
		if err == nil {
			return f
		}
	}
	return 0
}

// toString converts interface{} to string
func toString(v interface{}) string {
	if v == nil {
		return ""
	}
	switch val := v.(type) {
	case string:
		return val
	default:
		return fmt.Sprintf("%v", val)
	}
}

// FormatFloat formats a float with 2 decimal places
func FormatFloat(v float64) string {
	return fmt.Sprintf("%.2f", v)
}
