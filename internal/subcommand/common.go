package subcommand

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/utils"
)

// Record represents a generic metric record
type Record struct {
	InstID int
	SID    int
	Name   string
	Value1 int64   // For TotalWaits or similar
	Value2 float64 // For TimeWaited or Value
}

// QueryConfig holds query configuration
type QueryConfig struct {
	ViewName      string
	ValueColumns  []string // Column names to select
	FilterColumn  string   // Column name for name filter (e.g., "event" or "name")
	ExcludeFilter string   // Additional WHERE clause
	NoAlias       bool     // If true, don't add alias 'a' to ViewName
}

// CollectRecords collects records from database
func CollectRecords(ctx context.Context, conn connector.Connector, qc *QueryConfig, instIDs, sids, names string) ([]Record, error) {
	var filters []string

	// Add exclude filter if specified
	if qc.ExcludeFilter != "" {
		filters = append(filters, qc.ExcludeFilter)
	}

	// Parse and validate inst_id list
	if instIDs != "" {
		instIDList, err := utils.ParseCommaSeparatedInts(instIDs)
		if err != nil {
			return nil, fmt.Errorf("invalid inst_id: %w", err)
		}
		if len(instIDList) > 0 {
			clause := utils.BuildInClause("a.inst_id", instIDList)
			filters = append(filters, clause)
		}
	}

	// Parse and validate sid list
	if sids != "" {
		sidList, err := utils.ParseCommaSeparatedInts(sids)
		if err != nil {
			return nil, fmt.Errorf("invalid sid: %w", err)
		}
		if len(sidList) > 0 {
			clause := utils.BuildInClause("a.sid", sidList)
			filters = append(filters, clause)
		}
	}

	// Parse name filter
	if names != "" {
		nameList := utils.ParseCommaSeparatedStrings(names)
		if len(nameList) > 0 {
			clause := utils.BuildLikeClause(qc.FilterColumn, nameList)
			filters = append(filters, clause)
		}
	}

	whereClause := ""
	if len(filters) > 0 {
		whereClause = "WHERE " + strings.Join(filters, " AND ")
	}

	// Build FROM clause
	fromClause := qc.ViewName
	if !qc.NoAlias {
		fromClause = qc.ViewName + " a"
	}

	sql := fmt.Sprintf(`
SELECT a.inst_id, a.sid, %s, %s
FROM %s
%s
ORDER BY a.inst_id, a.sid, %s
`, qc.FilterColumn, strings.Join(qc.ValueColumns, ", "), fromClause, whereClause, qc.FilterColumn)

	rows, err := conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, err
	}

	var records []Record
	for _, row := range rows {
		expectedCols := 3 + len(qc.ValueColumns)
		if len(row) < expectedCols {
			continue
		}

		// Skip header
		if row[0] == "INST_ID" {
			continue
		}

		instIDVal, err := strconv.Atoi(row[0])
		if err != nil {
			continue
		}

		sidVal, err := strconv.Atoi(row[1])
		if err != nil {
			continue
		}

		rec := Record{
			InstID: instIDVal,
			SID:    sidVal,
			Name:   row[2],
		}

		// Parse value columns
		if len(qc.ValueColumns) >= 1 {
			val, err := strconv.ParseInt(row[3], 10, 64)
			if err == nil {
				rec.Value1 = val
			}
		}
		if len(qc.ValueColumns) >= 2 {
			val, err := strconv.ParseFloat(row[4], 64)
			if err == nil {
				rec.Value2 = val
			}
		}

		records = append(records, rec)
	}

	return records, nil
}

// CalculateDeltas calculates deltas between two snapshots
func CalculateDeltas(prev, curr []Record, interval int) []Record {
	prevMap := make(map[string]Record)
	for _, r := range prev {
		key := fmt.Sprintf("%d-%d-%s", r.InstID, r.SID, r.Name)
		prevMap[key] = r
	}

	var deltas []Record
	for _, r := range curr {
		key := fmt.Sprintf("%d-%d-%s", r.InstID, r.SID, r.Name)
		if prevRec, exists := prevMap[key]; exists {
			deltaVal1 := r.Value1 - prevRec.Value1
			deltaVal2 := r.Value2 - prevRec.Value2

			if deltaVal1 > 0 && deltaVal2 > 0 {
				deltas = append(deltas, Record{
					InstID: r.InstID,
					SID:    r.SID,
					Name:   r.Name,
					Value1: deltaVal1,
					Value2: deltaVal2,
				})
			}
		}
	}

	return deltas
}

// RunSubcommand runs a generic subcommand with sampling
func RunSubcommand(ctx context.Context, conn connector.Connector, qc *QueryConfig,
	interval, count, topN int, instIDs, sids, names string,
	displayFunc func([]Record, int, string, string, string, int, int)) {

	if count < 1 {
		count = 1
	}

	var prevRecords []Record

	// Total iterations = count + 1 (baseline + count results)
	totalIterations := count + 1

	for i := 0; i < totalIterations; i++ {
		if i > 0 {
			time.Sleep(time.Duration(interval) * time.Second)
		}

		records, err := CollectRecords(ctx, conn, qc, instIDs, sids, names)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error collecting data: %v\n", err)
			os.Exit(1)
		}

		if i == 0 {
			prevRecords = records
			fmt.Printf("Collecting baseline data...\n")
		} else {
			// Calculate deltas
			deltas := CalculateDeltas(prevRecords, records, interval)

			// Display results (i is the result number, count is total results)
			displayFunc(deltas, topN, instIDs, sids, names, i, count)

			prevRecords = records
		}
	}
}

// DisplayResults displays results with grouping logic
func DisplayResults(deltas []Record, topN int, instIDs, sids, names string,
	sample, totalSamples int, title string, showValue1 bool) {

	fmt.Printf("\n=== %s (Sample %d/%d) ===\n", title, sample, totalSamples)

	if len(deltas) == 0 {
		fmt.Println("No data with non-zero deltas found")
		return
	}

	// If no sid filter specified, group by session
	if sids == "" {
		displayGroupedBySessions(deltas, topN, showValue1)
	} else {
		displayDetailedRecords(deltas, topN, showValue1)
	}

	// Display filters
	if instIDs != "" {
		fmt.Printf("Filtered by: INST_ID IN (%s)\n", instIDs)
	}
	if names != "" {
		fmt.Printf("Filtered by: NAME LIKE (%s)\n", names)
	}
}

// displayGroupedBySessions displays records grouped by session
func displayGroupedBySessions(deltas []Record, topN int, showValue1 bool) {
	sessionTotals := make(map[string]struct {
		InstID     int
		SID        int
		TotalVal1  int64
		TotalVal2  float64
	})

	for _, d := range deltas {
		key := fmt.Sprintf("%d-%d", d.InstID, d.SID)
		entry := sessionTotals[key]
		entry.InstID = d.InstID
		entry.SID = d.SID
		entry.TotalVal1 += d.Value1
		entry.TotalVal2 += d.Value2
		sessionTotals[key] = entry
	}

	type SessionTotal struct {
		InstID    int
		SID       int
		TotalVal1 int64
		TotalVal2 float64
	}

	var sessions []SessionTotal
	var grandTotal float64
	for _, entry := range sessionTotals {
		sessions = append(sessions, SessionTotal{
			InstID:    entry.InstID,
			SID:       entry.SID,
			TotalVal1: entry.TotalVal1,
			TotalVal2: entry.TotalVal2,
		})
		grandTotal += entry.TotalVal2
	}

	// Sort by Value2 descending
	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].TotalVal2 > sessions[j].TotalVal2
	})

	// Take top N
	if len(sessions) > topN {
		sessions = sessions[:topN]
	}

	// Display header
	if showValue1 {
		fmt.Printf("%-8s %-10s %15s %15s %15s %10s\n",
			"INST_ID", "SID", "TOTAL_WAITS", "TIME_WAITED", "AVG_WAIT(ms)", "PCT%")
		fmt.Println(strings.Repeat("-", 80))

		// Display data
		for _, s := range sessions {
			avgWait := 0.0
			if s.TotalVal1 > 0 {
				avgWait = (s.TotalVal2 / float64(s.TotalVal1)) * 1000
			}
			pct := 0.0
			if grandTotal > 0 {
				pct = (s.TotalVal2 / grandTotal) * 100
			}
			fmt.Printf("%-8d %-10d %15d %15.2f %15.2f %9.2f%%\n",
				s.InstID, s.SID, s.TotalVal1, s.TotalVal2, avgWait, pct)
		}
	} else {
		fmt.Printf("%-8s %-10s %20s %10s\n",
			"INST_ID", "SID", "TOTAL_VALUE/SEC", "PCT%")
		fmt.Println(strings.Repeat("-", 50))

		// Display data
		for _, s := range sessions {
			pct := 0.0
			if grandTotal > 0 {
				pct = (s.TotalVal2 / grandTotal) * 100
			}
			fmt.Printf("%-8d %-10d %20.2f %9.2f%%\n",
				s.InstID, s.SID, s.TotalVal2, pct)
		}
	}

	fmt.Printf("\nShowing top %d sessions\n", len(sessions))
}

// displayDetailedRecords displays detailed records
func displayDetailedRecords(deltas []Record, topN int, showValue1 bool) {
	// Sort by Value2 descending
	sort.Slice(deltas, func(i, j int) bool {
		return deltas[i].Value2 > deltas[j].Value2
	})

	// Calculate total
	var totalVal2 float64
	for _, d := range deltas {
		totalVal2 += d.Value2
	}

	// Take top N
	if len(deltas) > topN {
		deltas = deltas[:topN]
	}

	// Display header
	if showValue1 {
		fmt.Printf("%-8s %-10s %-40s %15s %15s %15s %10s\n",
			"INST_ID", "SID", "NAME", "TOTAL_WAITS", "TIME_WAITED", "AVG_WAIT(ms)", "PCT%")
		fmt.Println(strings.Repeat("-", 120))

		// Display data
		for _, d := range deltas {
			avgWait := 0.0
			if d.Value1 > 0 {
				avgWait = (d.Value2 / float64(d.Value1)) * 1000
			}
			pct := 0.0
			if totalVal2 > 0 {
				pct = (d.Value2 / totalVal2) * 100
			}
			fmt.Printf("%-8d %-10d %-40s %15d %15.2f %15.2f %9.2f%%\n",
				d.InstID, d.SID, d.Name, d.Value1, d.Value2, avgWait, pct)
		}
	} else {
		fmt.Printf("%-8s %-10s %-50s %20s %10s\n",
			"INST_ID", "SID", "NAME", "VALUE/SEC", "PCT%")
		fmt.Println(strings.Repeat("-", 100))

		// Display data
		for _, d := range deltas {
			pct := 0.0
			if totalVal2 > 0 {
				pct = (d.Value2 / totalVal2) * 100
			}
			fmt.Printf("%-8d %-10d %-50s %20.2f %9.2f%%\n",
				d.InstID, d.SID, d.Name, d.Value2, pct)
		}
	}

	fmt.Printf("\nShowing top %d records\n", len(deltas))
}
