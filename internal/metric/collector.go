package metric

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/scripts"
)

// Snapshot represents a single data collection snapshot
type Snapshot struct {
	Timestamp time.Time
	Columns   []string
	Rows      []map[string]interface{}
}

// ColumnInfo holds metadata about detected columns
type ColumnInfo struct {
	GroupColumn   string   // Column used for grouping (e.g., "INST_ID")
	ValueColumns  []string // Columns that contain numeric values (for delta calculation)
	StringColumns []string // Columns that contain string/time values (display as-is)
}

// Collector collects metrics from SQL queries
type Collector struct {
	conn       connector.Connector
	sqlFile    string
	sql        string
	columnInfo *ColumnInfo
}

// NewCollector creates a new metric collector
func NewCollector(conn connector.Connector, sqlFile string) *Collector {
	return &Collector{
		conn:    conn,
		sqlFile: sqlFile,
	}
}

// Collect executes the SQL and returns a snapshot
func (c *Collector) Collect(ctx context.Context) (*Snapshot, error) {
	// Read SQL from file (only once)
	if c.sql == "" {
		sql, err := scripts.GetSQLScript(c.sqlFile)
		if err != nil {
			return nil, err
		}
		c.sql = sql
	}

	// Execute query with header
	header, rows, err := c.conn.ExecuteQueryWithHeader(ctx, c.sql)
	if err != nil {
		return nil, err
	}

	if len(rows) == 0 || len(header) == 0 {
		return nil, nil
	}

	// Detect column info on first collection
	if c.columnInfo == nil {
		c.columnInfo = detectColumnInfo(header, rows)
	}

	// Build column names list
	var columnNames []string
	if c.columnInfo.GroupColumn != "" {
		columnNames = append(columnNames, c.columnInfo.GroupColumn)
	}
	columnNames = append(columnNames, c.columnInfo.ValueColumns...)

	// Parse data rows
	parsedRows := make([]map[string]interface{}, 0, len(rows))
	for _, row := range rows {
		// Map header -> value
		rowMap := make(map[string]interface{})
		for i, col := range header {
			if i < len(row) {
				rowMap[strings.ToUpper(col)] = row[i]
			}
		}
		parsedRows = append(parsedRows, rowMap)
	}

	return &Snapshot{
		Timestamp: time.Now(),
		Columns:   header,
		Rows:      parsedRows,
	}, nil
}

// GetColumnInfo returns the detected column information
func (c *Collector) GetColumnInfo() *ColumnInfo {
	return c.columnInfo
}

// detectColumnInfo analyzes the result set to determine grouping and value columns
func detectColumnInfo(header []string, sampleRows [][]string) *ColumnInfo {
	info := &ColumnInfo{
		ValueColumns:  make([]string, 0),
		StringColumns: make([]string, 0),
	}

	// Normalize header to uppercase
	upperHeader := make([]string, len(header))
	for i, col := range header {
		upperHeader[i] = strings.ToUpper(col)
	}

	// Find group column (look for INST_ID)
	for _, col := range upperHeader {
		if col == "INST_ID" {
			info.GroupColumn = col
			break
		}
	}

	// Determine value columns and string columns
	for colIdx, colName := range upperHeader {
		if colName == info.GroupColumn {
			continue
		}

		// Check if this column contains numeric values
		if isNumericColumn(colIdx, sampleRows) {
			info.ValueColumns = append(info.ValueColumns, colName)
		} else {
			info.StringColumns = append(info.StringColumns, colName)
		}
	}

	return info
}

// isNumericColumn checks if a column contains numeric values
func isNumericColumn(colIdx int, rows [][]string) bool {
	// Check first few data rows
	numericCount := 0
	totalCount := 0

	for i := 0; i < len(rows) && i < 5; i++ {
		if len(rows[i]) <= colIdx {
			continue
		}
		totalCount++
		val := rows[i][colIdx]
		if _, err := strconv.ParseFloat(strings.TrimSpace(val), 64); err == nil {
			numericCount++
		}
	}

	// If more than 80% of values are numeric, treat as numeric column
	return totalCount > 0 && float64(numericCount)/float64(totalCount) >= 0.8
}
