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

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSysStats SQL:\n%s\n", sql)
	}

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query gv$sysstat: %w", err)
	}

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSysStats returned %d rows\n", len(rows))
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

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSystemEvents SQL:\n%s\n", sql)
	}

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query gv$system_event: %w", err)
	}

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSystemEvents returned %d rows\n", len(rows))
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
	sessionMetrics := c.cfg.SessionStatMetricsList()
	metricList := make([]string, len(sessionMetrics))
	for i, m := range sessionMetrics {
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
    s.PROGRAM,
    n.NAME,
    st.VALUE
FROM GV$SESSION s
LEFT JOIN GV$PROCESS p ON s.INST_ID = p.INST_ID AND s.PADDR = p.THREAD_ADDR
JOIN GV$SESSTAT st ON s.INST_ID = st.INST_ID AND s.SID = st.SID
JOIN GV$STATNAME n ON st.INST_ID = n.INST_ID AND st.STATISTIC# = n.STATISTIC#
WHERE n.NAME IN (%s)
  AND s.USERNAME IS NOT NULL
  AND s.TYPE != 'BACKGROUND'
  AND NOT (s.INST_ID = TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE'))
       AND s.SID = TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')))%s
ORDER BY s.INST_ID, s.SID, n.NAME
`, strings.Join(metricList, ","), instFilter)

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSessionMetrics SQL:\n%s\n", sql)
	}

	rows, err := c.conn.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query session metrics: %w", err)
	}

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSessionMetrics returned %d rows\n", len(rows))
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

// CollectSessionDetails collects active session details (same session filter as we.sql).
// Note: CollectSessionMetrics does not filter INACTIVE status; this query does.
func (c *Collector) CollectSessionDetails(ctx context.Context) ([]models.SessionDetail, error) {
	instFilter := ""
	if c.cfg.InstanceID > 0 {
		instFilter = fmt.Sprintf(" AND a.INST_ID = %d", c.cfg.InstanceID)
	}

	// 与 we.sql 对齐: 在 SQL 内把 exec_ms 格式化为字符列 exect, 避免 NUMBER + COL FOR An.
	sqlBody := fmt.Sprintf(`
SELECT
    sid_tid,
    event,
    username,
    sql_id,
    CASE
        WHEN exec_ms IS NULL THEN
            'N/A'
        WHEN exec_ms < 1000 THEN
            ROUND(exec_ms, 0) || 'MS'
        WHEN exec_ms < 60000 THEN
            ROUND(exec_ms / 1000, 2) || 'S'
        WHEN exec_ms < 3600000 THEN
            ROUND(exec_ms / 60000, 2) || 'M'
        WHEN exec_ms < 86400000 THEN
            ROUND(exec_ms / 3600000, 2) || 'H'
        ELSE
            ROUND(exec_ms / 86400000, 2) || 'D'
    END AS exect,
    program,
    client,
    TO_CHAR(inst_id) AS inst_id
FROM (
    SELECT
        x.sid_tid,
        x.event,
        x.username,
        x.program,
        x.sql_id,
        GREATEST(0,
            EXTRACT(DAY FROM x.exec_delta) * 86400000 +
            EXTRACT(HOUR FROM x.exec_delta) * 3600000 +
            EXTRACT(MINUTE FROM x.exec_delta) * 60000 +
            EXTRACT(SECOND FROM x.exec_delta) * 1000
        ) AS exec_ms,
        x.client,
        x.inst_id
    FROM (
        SELECT
            a.inst_id||'.'||a.sid||'.'||a.serial#||'.'
              ||NVL(TO_CHAR(NVL(b.thread_id, schd.thread_id)), '-') AS sid_tid,
            substr(a.wait_event,1,30) AS event,
            a.username AS username,
            substr(NVL(a.cli_program, NVL(j.job_name, a.module)),1,30) AS program,
            substr(c.command_name,1,3)||'.'||nvl(a.sql_id,a.sql_id) AS sql_id,
            CASE
                WHEN a.exec_start_time IS NOT NULL THEN
                    CAST(
                        CAST(SYSTIMESTAMP AS TIMESTAMP(6))
                          - CAST(a.exec_start_time AS TIMESTAMP(6))
                        AS INTERVAL DAY(9) TO SECOND(6)
                    )
                WHEN j.last_start_date IS NOT NULL THEN
                    CAST(
                        CAST(SYSTIMESTAMP AS TIMESTAMP(6))
                          - CAST(j.last_start_date AS TIMESTAMP(6))
                        AS INTERVAL DAY(9) TO SECOND(6)
                    )
                ELSE NULL
            END AS exec_delta,
            CASE
                WHEN a.ip_address IS NULL THEN NULL
                ELSE a.ip_address||'.'||a.ip_port
            END AS client,
            a.inst_id
        FROM GV$SESSION a
        LEFT JOIN GV$PROCESS b
          ON a.inst_id = b.inst_id
         AND a.paddr = b.thread_addr
        LEFT JOIN (
            SELECT
                job_name,
                running_instance,
                last_start_date,
                ROW_NUMBER() OVER (
                    PARTITION BY NVL(running_instance, 1)
                    ORDER BY last_start_date, job_name
                ) AS rn
            FROM DBA_SCHEDULER_JOBS
            WHERE state = 'RUNNING'
        ) j
          ON a.inst_id = NVL(j.running_instance, a.inst_id)
         AND (
                (a.action IS NOT NULL AND a.action = j.job_name)
             OR (a.module IS NOT NULL AND a.module = j.job_name)
         )
        LEFT JOIN (
            SELECT
                inst_id,
                thread_id,
                ROW_NUMBER() OVER (
                    PARTITION BY inst_id
                    ORDER BY start_time, thread_id
                ) AS rn
            FROM GV$PROCESS
            WHERE name = 'DBMS_SCHEDULER'
        ) schd
          ON schd.inst_id = a.inst_id
         AND j.job_name IS NOT NULL
         AND schd.rn = j.rn
        LEFT JOIN V$SQLCOMMAND c
          ON a.command = c.command_type
        WHERE a.TYPE NOT IN ('BACKGROUND')
          AND NVL(NULLIF(TRIM(a.status), ''), 'ACTIVE') NOT IN ('INACTIVE')
          AND NOT (a.INST_ID = TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE'))
               AND a.SID = TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')))%s
    ) x
    ORDER BY exec_ms DESC NULLS LAST
    FETCH FIRST %d ROWS ONLY
)
`, instFilter, c.cfg.SessionDetailTopN)

	sql := sessionDetailColPrefix(c.cfg.DBType) + sqlBody

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSessionDetails SQL:\n%s\n", sql)
	}

	header, rows, err := c.conn.ExecuteQueryWithHeader(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("failed to query session details: %w", err)
	}

	if c.cfg.DebugMode {
		logger.Debug("[collector] CollectSessionDetails header: %v\n", header)
		logger.Debug("[collector] CollectSessionDetails returned %d rows\n", len(rows))
	}

	var details []models.SessionDetail
	for _, row := range rows {
		detail, ok := parseSessionDetailRow(header, row)
		if !ok {
			if c.cfg.DebugMode {
				logger.Debug("[collector] skipping session detail row: %v\n", row)
			}
			continue
		}
		details = append(details, detail)
	}

	if c.cfg.DebugMode && len(rows) > 0 && len(details) == 0 {
		logger.Debug("[collector] CollectSessionDetails: %d raw rows parsed to 0 details\n", len(rows))
	}

	return details, nil
}

// sessionDetailColPrefix sets fixed column widths for yasql table output (aligned with we.sql).
// 全部为字符列(含 TO_CHAR(inst_id) / CASE 拼出的 exect), 避免 NUMBER 直接 COL FOR An.
// 显示别名 EXECT + a6: 与 we.sql 一致, 表头与值同宽不截断.
func sessionDetailColPrefix(dbType string) string {
	switch dbType {
	case "yashandb", "oracle", "dameng":
		return `col SID_TID for a20
col EVENT for a20
col USERNAME for a15
col SQL_ID for a20
col EXECT for a6
col PROGRAM for a30
col CLIENT for a20
col INST_ID for a7
`
	default:
		return ""
	}
}

func sessionDetailColumnIndex(header []string) map[string]int {
	idx := make(map[string]int, len(header))
	for i, h := range header {
		key := normalizeSessionDetailHeader(h)
		if key != "" {
			idx[key] = i
		}
	}
	return idx
}

func normalizeSessionDetailHeader(h string) string {
	h = strings.ToUpper(strings.TrimSpace(h))
	h = strings.ReplaceAll(h, " ", "_")
	switch h {
	case "EXECT", "EXEC_T", "EXEC_MS", "EXEC_TIM", "EXEC_TIME": // EXECT: we.sql 短名; EXEC_TIM: 旧 a8 截断兼容
		return "EXEC_TIME"
	case "SID", "SID_SERIAL", "SID.SERIAL":
		return "SID_TID"
	}
	return h
}

func parseSessionDetailRow(header, row []string) (models.SessionDetail, bool) {
	if len(row) == 0 {
		return models.SessionDetail{}, false
	}

	get := func(keys ...string) string {
		idx := sessionDetailColumnIndex(header)
		for _, k := range keys {
			if i, ok := idx[normalizeSessionDetailHeader(k)]; ok && i < len(row) {
				return strings.TrimSpace(row[i])
			}
		}
		return ""
	}

	var (
		sidTid   string
		event    string
		username string
		sqlID    string
		program  string
		client   string
		execTime string
		instID   int
	)

	if len(header) > 0 {
		sidTid = get("SID_TID")
		event = get("EVENT")
		username = get("USERNAME")
		sqlID = get("SQL_ID")
		program = get("PROGRAM")
		client = get("CLIENT")
		instID = parseSessionDetailInt(get("INST_ID"))
		execTime = resolveExecTime(get("EXEC_TIME", "EXEC_MS"))
		// 表头仍截断/错位时, 按 SELECT 第 5 列 (exec_time) 回退
		if !hasExecTimeSuffix(execTime) && len(row) >= 5 {
			if raw := strings.TrimSpace(row[4]); hasExecTimeSuffix(raw) {
				execTime = resolveExecTime(raw)
			}
		}
	} else if len(row) >= 8 {
		// Fallback: column order aligned with we.sql / CollectSessionDetails SELECT.
		sidTid = strings.TrimSpace(row[0])
		event = row[1]
		username = row[2]
		sqlID = row[3]
		execTime = resolveExecTime(row[4])
		program = row[5]
		client = row[6]
		instID = parseSessionDetailInt(row[7])
	} else {
		return models.SessionDetail{}, false
	}

	if sidTid == "" || strings.EqualFold(sidTid, "SID_TID") {
		return models.SessionDetail{}, false
	}

	return models.SessionDetail{
		InstID:   instID,
		SidTid:   sidTid,
		Event:    event,
		Username: username,
		SqlID:    sqlID,
		Program:  program,
		ExecTime: execTime,
		Client:   client,
	}, true
}

func hasExecTimeSuffix(s string) bool {
	upper := strings.ToUpper(strings.TrimSpace(s))
	for _, suffix := range []string{"MS", "S", "M", "H", "D"} {
		if strings.HasSuffix(upper, suffix) && len(upper) > len(suffix) {
			return true
		}
	}
	return false
}

// resolveExecTime 优先沿用 we.sql 已格式化的 MS/S/M/H/D 字符串; 否则按毫秒数值再格式化.
// 当 exec_start_time 为 NULL 时 SQL 输出 'N/A'; 单字符后缀 (如裸 'D') 也是 NULL 串联残留, 按 N/A 处理.
func resolveExecTime(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "N/A"
	}
	upper := strings.ToUpper(s)
	// SQL outputs 'N/A' when exec_start_time is NULL — pass through directly.
	if upper == "N/A" {
		return s
	}
	// Single-character suffix strings (e.g. bare 'D' from NULL concatenation) are not valid times.
	if len(s) == 1 {
		return "N/A"
	}
	for _, suffix := range []string{"MS", "S", "M", "H", "D"} {
		if strings.HasSuffix(upper, suffix) && len(s) > len(suffix) {
			return s
		}
	}
	// Numeric fallback — but 0 from failed parsing is misleading; return N/A.
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || v < 0 {
		return "N/A"
	}
	return formatExecTime(v)
}

func parseSessionDetailInt(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if v, err := strconv.Atoi(s); err == nil {
		return v
	}
	if v, err := strconv.ParseFloat(s, 64); err == nil {
		return int(v)
	}
	return 0
}

// formatExecTime formats elapsed time from milliseconds using MS/S/M/H/D (aligned with we.sql).
func formatExecTime(execMs float64) string {
	if execMs < 0 {
		execMs = 0
	}
	switch {
	case execMs < 1000:
		return fmt.Sprintf("%.0fMS", execMs)
	case execMs < 60000:
		return fmt.Sprintf("%.2fS", execMs/1000)
	case execMs < 3600000:
		return fmt.Sprintf("%.2fM", execMs/60000)
	case execMs < 86400000:
		return fmt.Sprintf("%.2fH", execMs/3600000)
	default:
		return fmt.Sprintf("%.2fD", execMs/86400000)
	}
}
