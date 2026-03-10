package models

import "time"

// SysStatMetric represents a single v$sysstat metric
type SysStatMetric struct {
	InstID       int
	Name         string
	CurrentValue float64
	DeltaPerSec  float64
}

// SystemEvent represents a v$system_event entry
type SystemEvent struct {
	InstID      int
	EventName   string
	TotalWaits  int64
	TimeWaited  float64
	AvgWaitTime float64
	Percentage  float64
}

// SessionMetric represents session-level statistics
type SessionMetric struct {
	InstID   int
	SID      int
	Serial   int
	ThreadID int
	SidTid   string // Combined "SID.SERIAL#.THREAD_ID"
	Username string
	SqlID    string
	Program  string
	Metrics  map[string]float64 // metric name -> value
}

// SessionDetail represents detailed session information
type SessionDetail struct {
	InstID   int
	SidTid   string
	Event    string
	Username string
	SqlID    string
	ExecTime string
	Program  string
	Client   string
}

// Snapshot represents a complete data snapshot
type Snapshot struct {
	Timestamp      time.Time
	SysStats       []SysStatMetric
	SystemEvents   []SystemEvent
	SessionMetrics []SessionMetric
	SessionDetails []SessionDetail
}
