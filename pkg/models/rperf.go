package models

import "time"

type RperfMetricData struct {
	Results []struct {
		Target  string  `json:"target"`
		Success bool    `json:"success"`
		Error   *string `json:"error"`
		Summary struct {
			BitsPerSecond   float64 `json:"bits_per_second"`
			BytesReceived   int64   `json:"bytes_received"`
			BytesSent       int64   `json:"bytes_sent"`
			Duration        float64 `json:"duration"`
			JitterMs        float64 `json:"jitter_ms"`
			LossPercent     float64 `json:"loss_percent"`
			PacketsLost     int64   `json:"packets_lost"`
			PacketsReceived int64   `json:"packets_received"`
			PacketsSent     int64   `json:"packets_sent"`
		} `json:"summary"`
	} `json:"results"`
	Timestamp string `json:"timestamp"`
}

// RperfMetrics represents rperf-specific metrics.
type RperfMetrics struct {
	Results []RperfMetric `json:"results"`
}

type RperfMetric struct {
	Timestamp       time.Time `json:"timestamp"`
	Name            string    `json:"name"` // e.g., "rperf_tcp_test"
	BitsPerSecond   float64   `json:"bits_per_second"`
	BytesReceived   int64     `json:"bytes_received"`
	BytesSent       int64     `json:"bytes_sent"`
	Duration        float64   `json:"duration"`
	JitterMs        float64   `json:"jitter_ms"`
	LossPercent     float64   `json:"loss_percent"`
	PacketsLost     int64     `json:"packets_lost"`
	PacketsReceived int64     `json:"packets_received"`
	PacketsSent     int64     `json:"packets_sent"`
	Success         bool      `json:"success"`
	Target          string    `json:"target"` // e.g., "TCP Test"
	Error           *string   `json:"error,omitempty"`
}

type RperfMetricResponse struct {
	Metrics []RperfMetric
	Err     error
}
