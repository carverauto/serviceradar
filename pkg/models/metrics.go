// Package models pkg/models/metrics.go
package models

import "time"

type MetricPoint struct {
	Timestamp    time.Time `json:"timestamp"`
	ResponseTime int64     `json:"response_time"`
	ServiceName  string    `json:"service_name"`
}

type MetricsConfig struct {
	Enabled   bool `json:"metrics_enabled"`
	Retention int  `json:"metrics_retention"`
	MaxNodes  int  `json:"max_nodes"`
}
