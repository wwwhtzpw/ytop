package calculator

import (
	"fmt"
	"sort"
	"time"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/models"
)

// Calculator calculates deltas and rankings
type Calculator struct {
	cfg                *config.Config
	prevSysStats       map[string]float64
	prevTimestamp      time.Time
	prevSystemEvents   map[string]models.SystemEvent
	prevSessionMetrics map[string]models.SessionMetric // key: "SID-Serial"
}

// NewCalculator creates a new calculator
func NewCalculator(cfg *config.Config) *Calculator {
	return &Calculator{
		cfg:                cfg,
		prevSysStats:       make(map[string]float64),
		prevSystemEvents:   make(map[string]models.SystemEvent),
		prevSessionMetrics: make(map[string]models.SessionMetric),
	}
}

// CalculateSysStatDeltas calculates per-second deltas for sysstat metrics
func (c *Calculator) CalculateSysStatDeltas(metrics []models.SysStatMetric, timestamp time.Time) []models.SysStatMetric {
	if c.prevTimestamp.IsZero() {
		// First run, just store current values
		for _, m := range metrics {
			key := fmt.Sprintf("%d-%s", m.InstID, m.Name)
			c.prevSysStats[key] = m.CurrentValue
		}
		c.prevTimestamp = timestamp
		return metrics
	}

	// Calculate time difference in seconds
	timeDiff := timestamp.Sub(c.prevTimestamp).Seconds()
	if timeDiff <= 0 {
		timeDiff = 1
	}

	// Calculate deltas
	result := make([]models.SysStatMetric, len(metrics))
	for i, m := range metrics {
		result[i] = m
		key := fmt.Sprintf("%d-%s", m.InstID, m.Name)
		if prevValue, exists := c.prevSysStats[key]; exists {
			delta := m.CurrentValue - prevValue
			result[i].DeltaPerSec = delta / timeDiff
		}
		c.prevSysStats[key] = m.CurrentValue
	}

	c.prevTimestamp = timestamp

	return result
}

// CalculateSystemEventDeltas calculates deltas for system events
func (c *Calculator) CalculateSystemEventDeltas(events []models.SystemEvent) []models.SystemEvent {
	if len(c.prevSystemEvents) == 0 {
		// First run, just store current values and return empty result
		for _, e := range events {
			key := fmt.Sprintf("%d-%s", e.InstID, e.EventName)
			c.prevSystemEvents[key] = e
		}
		return []models.SystemEvent{}
	}

	// Calculate deltas
	result := make([]models.SystemEvent, 0, len(events))
	var totalTime float64

	for _, e := range events {
		key := fmt.Sprintf("%d-%s", e.InstID, e.EventName)
		if prev, exists := c.prevSystemEvents[key]; exists {
			deltaWaits := e.TotalWaits - prev.TotalWaits
			deltaTime := e.TimeWaited - prev.TimeWaited

			if deltaWaits > 0 && deltaTime > 0 {
				result = append(result, models.SystemEvent{
					InstID:      e.InstID,
					EventName:   e.EventName,
					TotalWaits:  deltaWaits,
					TimeWaited:  deltaTime,
					AvgWaitTime: deltaTime / float64(deltaWaits),
				})
				totalTime += deltaTime
			}
		}
		c.prevSystemEvents[key] = e
	}

	// Calculate percentages
	for i := range result {
		if totalTime > 0 {
			result[i].Percentage = (result[i].TimeWaited / totalTime) * 100
		}
	}

	// Sort by time waited descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].TimeWaited > result[j].TimeWaited
	})

	// Take top N
	if len(result) > c.cfg.EventTopN {
		result = result[:c.cfg.EventTopN]
	}

	return result
}

// RankSessionMetrics ranks sessions by specified metric and calculates per-second deltas
func (c *Calculator) RankSessionMetrics(metrics []models.SessionMetric, timestamp time.Time) []models.SessionMetric {
	result := make([]models.SessionMetric, 0, len(metrics))

	// Calculate time difference in seconds
	var timeDiff float64
	if !c.prevTimestamp.IsZero() {
		timeDiff = timestamp.Sub(c.prevTimestamp).Seconds()
		if timeDiff <= 0 {
			timeDiff = 1
		}
	}

	// Calculate deltas if we have previous data
	if len(c.prevSessionMetrics) > 0 && timeDiff > 0 {
		for _, m := range metrics {
			key := fmt.Sprintf("%d-%d-%d", m.InstID, m.SID, m.Serial)

			// Check if we have previous data for this session
			if prev, exists := c.prevSessionMetrics[key]; exists {
				// Calculate deltas per second for all metrics
				deltaMetrics := make(map[string]float64)
				for metricName, currentValue := range m.Metrics {
					if prevValue, ok := prev.Metrics[metricName]; ok {
						delta := currentValue - prevValue
						if delta > 0 {
							deltaMetrics[metricName] = delta / timeDiff
						} else {
							deltaMetrics[metricName] = 0
						}
					} else {
						deltaMetrics[metricName] = currentValue / timeDiff
					}
				}

				// Create new session metric with delta per second values
				result = append(result, models.SessionMetric{
					InstID:   m.InstID,
					SID:      m.SID,
					Serial:   m.Serial,
					ThreadID: m.ThreadID,
					SidTid:   m.SidTid,
					Username: m.Username,
					SqlID:    m.SqlID,
					Program:  m.Program,
					Metrics:  deltaMetrics,
				})
			} else {
				// New session, show zero values
				zeroMetrics := make(map[string]float64)
				for metricName := range m.Metrics {
					zeroMetrics[metricName] = 0
				}
				result = append(result, models.SessionMetric{
					InstID:   m.InstID,
					SID:      m.SID,
					Serial:   m.Serial,
					ThreadID: m.ThreadID,
					SidTid:   m.SidTid,
					Username: m.Username,
					SqlID:    m.SqlID,
					Program:  m.Program,
					Metrics:  zeroMetrics,
				})
			}
		}
	}

	// Store current metrics (with original cumulative values) for next iteration
	c.prevSessionMetrics = make(map[string]models.SessionMetric)
	for _, m := range metrics {
		key := fmt.Sprintf("%d-%d-%d", m.InstID, m.SID, m.Serial)
		c.prevSessionMetrics[key] = m
	}

	// First iteration, return empty result (don't show cumulative values)
	if len(result) == 0 {
		return result
	}

	// Sort by the specified metric
	sort.Slice(result, func(i, j int) bool {
		valI := result[i].Metrics[c.cfg.SessionSortBy]
		valJ := result[j].Metrics[c.cfg.SessionSortBy]
		return valI > valJ
	})

	// Take top N
	if len(result) > c.cfg.SessionTopN {
		result = result[:c.cfg.SessionTopN]
	}

	return result
}
