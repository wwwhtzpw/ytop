package collector

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/logger"
	"github.com/yihan/ytop/internal/models"
)

// Collector collects metrics from YashanDB
type Collector struct {
	cfg  *config.Config
	conn connector.Connector
}

// NewCollector creates a new collector
func NewCollector(cfg *config.Config, conn connector.Connector) *Collector {
	return &Collector{
		cfg:  cfg,
		conn: conn,
	}
}

// CollectSysStats collects v$sysstat metrics
func (c *Collector) CollectSysStats(ctx context.Context) ([]models.SysStatMetric, error) {
	// Build SQL with metric names
	metricList := make([]string, len(c.cfg.SysStatMetrics))
	for i, m := range c.cfg.SysStatMetrics {
		metricList[i] = fmt.Sprintf("'%s'", m)
	}

	instFilter := ""
	if c.cfg.InstanceID > 0 {
		instFilter = fmt.Sprintf(" AND INST_ID = %d", c.cfg.InstanceID)
	}

	sql := fmt.Sprintf(`
SELECT INST_ID, NAME, VALUE
FROM GV$SYSSTAT
WHERE NAME IN (%s)%s
ORDER BY INST_ID, NAME
`, strings.Join(metricList, ","), instFilter)

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query gv$sysstat: %w", err)
	}

	var metrics []models.SysStatMetric
	for _, row := range rows {
		if len(row) < 3 {
			continue
		}

		// Skip header row
		if row[0] == "INST_ID" {
			continue
		}

		instID, err := strconv.Atoi(row[0])
		if err != nil {
			if c.cfg.DebugMode {
				logger.Debug("Failed to parse inst_id %s: %v\n", row[0], err)
			}
			continue
		}

		value, err := strconv.ParseFloat(row[2], 64)
		if err != nil {
			if c.cfg.DebugMode {
				logger.Debug("Failed to parse value for %s: %v\n", row[1], err)
			}
			continue
		}

		metrics = append(metrics, models.SysStatMetric{
			InstID:       instID,
			Name:         row[1],
			CurrentValue: value,
		})
	}

	return metrics, nil
}

// CollectSystemEvents collects v$system_event metrics
// Returns ALL events (not limited) so calculator can compute deltas and rank by interval activity
func (c *Collector) CollectSystemEvents(ctx context.Context) ([]models.SystemEvent, error) {
	instFilter := ""
	if c.cfg.InstanceID > 0 {
		instFilter = fmt.Sprintf(" AND INST_ID = %d", c.cfg.InstanceID)
	}

	sql := fmt.Sprintf(`
SELECT INST_ID, EVENT, TOTAL_WAITS, TIME_WAITED_MICRO/1000000 AS TIME_WAITED
FROM GV$SYSTEM_EVENT
WHERE EVENT NOT LIKE 'SQL*Net%%'
  AND EVENT NOT LIKE '%%idle%%'%s
ORDER BY INST_ID, EVENT
`, instFilter)

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query gv$system_event: %w", err)
	}

	var events []models.SystemEvent

	for _, row := range rows {
		if len(row) < 4 {
			continue
		}

		// Skip header row
		if row[0] == "INST_ID" {
			continue
		}

		instID, err := strconv.Atoi(row[0])
		if err != nil {
			continue
		}

		totalWaits, err := strconv.ParseInt(row[2], 10, 64)
		if err != nil {
			continue
		}

		timeWaited, err := strconv.ParseFloat(row[3], 64)
		if err != nil {
			continue
		}

		events = append(events, models.SystemEvent{
			InstID:     instID,
			EventName:  row[1],
			TotalWaits: totalWaits,
			TimeWaited: timeWaited,
		})
	}

	return events, nil
}

// CollectSessionMetrics collects session-level metrics
func (c *Collector) CollectSessionMetrics(ctx context.Context) ([]models.SessionMetric, error) {
	// Build metric list
	metricList := make([]string, len(c.cfg.SysStatMetrics))
	for i, m := range c.cfg.SysStatMetrics {
		metricList[i] = fmt.Sprintf("'%s'", m)
	}

	instFilter := ""
	if c.cfg.InstanceID > 0 {
		instFilter = fmt.Sprintf(" AND s.INST_ID = %d", c.cfg.InstanceID)
	}

	sql := fmt.Sprintf(`
SELECT
    s.INST_ID,
    s.SID,
    s.SERIAL#,
    p.THREAD_ID,
    s.USERNAME,
    s.SQL_ID,
    s.CLIENT_INFO,
    n.NAME,
    st.VALUE
FROM GV$SESSION s
JOIN GV$PROCESS p ON s.INST_ID = p.INST_ID AND s.PADDR = p.THREAD_ADDR
JOIN GV$SESSTAT st ON s.INST_ID = st.INST_ID AND s.SID = st.SID
JOIN GV$STATNAME n ON st.INST_ID = n.INST_ID AND st.STATISTIC# = n.STATISTIC#
WHERE n.NAME IN (%s)
  AND s.USERNAME IS NOT NULL
  AND s.TYPE != 'BACKGROUND'%s
ORDER BY s.INST_ID, s.SID, n.NAME
`, strings.Join(metricList, ","), instFilter)

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query session metrics: %w", err)
	}

	// Group by instance and session
	sessionMap := make(map[string]*models.SessionMetric)

	for _, row := range rows {
		if len(row) < 9 {
			continue
		}

		// Skip header row
		if row[0] == "INST_ID" {
			continue
		}

		instID, err := strconv.Atoi(row[0])
		if err != nil {
			continue
		}

		sid, err := strconv.Atoi(row[1])
		if err != nil {
			continue
		}

		serial, err := strconv.Atoi(row[2])
		if err != nil {
			continue
		}

		threadID, err := strconv.Atoi(row[3])
		if err != nil {
			continue
		}

		username := row[4]
		sqlID := row[5]
		program := row[6]
		metricName := row[7]

		value, err := strconv.ParseFloat(row[8], 64)
		if err != nil {
			continue
		}

		key := fmt.Sprintf("%d-%d-%d", instID, sid, serial)
		if _, exists := sessionMap[key]; !exists {
			sessionMap[key] = &models.SessionMetric{
				InstID:   instID,
				SID:      sid,
				Serial:   serial,
				ThreadID: threadID,
				SidTid:   fmt.Sprintf("%d.%d.%d", sid, serial, threadID),
				Username: username,
				SqlID:    sqlID,
				Program:  program,
				Metrics:  make(map[string]float64),
			}
		}

		sessionMap[key].Metrics[metricName] = value
	}

	// Convert map to slice
	var metrics []models.SessionMetric
	for _, m := range sessionMap {
		metrics = append(metrics, *m)
	}

	return metrics, nil
}

// CollectSessionDetails collects detailed session information
func (c *Collector) CollectSessionDetails(ctx context.Context) ([]models.SessionDetail, error) {
	instFilter := ""
	if c.cfg.InstanceID > 0 {
		instFilter = fmt.Sprintf(" AND a.INST_ID = %d", c.cfg.InstanceID)
	}

	sql := fmt.Sprintf(`
SELECT
    a.inst_id||'.'||a.sid||'.'||a.serial#||'.'||b.thread_id AS sid_tid,
    substr(a.wait_event,1,30) AS event,
    a.username AS username,
    substr(a.cli_program,1,30) AS program,
    substr(c.command_name,1,3)||'.'||nvl(a.sql_id,a.sql_id) AS sql_id,
    EXTRACT(DAY FROM (sysdate-a.exec_start_time)) * 86400 +
    EXTRACT(HOUR FROM (sysdate-a.exec_start_time)) * 3600 +
    EXTRACT(MINUTE FROM (sysdate-a.exec_start_time)) * 60 +
    EXTRACT(SECOND FROM (sysdate-a.exec_start_time)) AS exec_seconds,
    a.ip_address||'.'||a.ip_port AS client,
    a.inst_id
FROM GV$SESSION a, GV$PROCESS b, V$SQLCOMMAND c
WHERE a.inst_id = b.inst_id
  AND a.paddr = b.thread_addr
  AND a.command = c.command_type(+)
  AND a.TYPE NOT IN ('BACKGROUND')
  AND a.status NOT IN ('INACTIVE')%s
ORDER BY exec_seconds DESC
FETCH FIRST %d ROWS ONLY
`, instFilter, c.cfg.SessionDetailTopN)

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query session details: %w", err)
	}

	var details []models.SessionDetail
	for _, row := range rows {
		if len(row) < 8 {
			continue
		}

		// Skip header row
		if row[0] == "SID_TID" {
			continue
		}

		// SQL returns: sid_tid, event, username, program, sql_id, exec_seconds, client, inst_id
		execSeconds, _ := strconv.ParseFloat(row[5], 64)
		execTime := formatExecTime(execSeconds)

		instID, _ := strconv.Atoi(row[7])

		details = append(details, models.SessionDetail{
			InstID:   instID,
			SidTid:   row[0],
			Event:    row[1],
			Username: row[2],
			Program:  row[3],
			SqlID:    row[4],
			ExecTime: execTime,
			Client:   row[6],
		})
	}

	return details, nil
}

// formatExecTime formats execution time in MS/S/KS/WS format
func formatExecTime(seconds float64) string {
	if seconds < 1 {
		return fmt.Sprintf("%.0fMS", seconds*1000)
	} else if seconds < 1000 {
		return fmt.Sprintf("%.2fS", seconds)
	} else if seconds < 10000 {
		return fmt.Sprintf("%.2fKS", seconds/1000)
	} else {
		return fmt.Sprintf("%.2fWS", seconds/10000)
	}
}
