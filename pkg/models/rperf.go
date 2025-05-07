/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package models

import "time"

// RperfMetricData represents raw data received from the rperf service.
// @Description Raw network performance test data received from the rperf service.
type RperfMetricData struct {
	// Array of test results for different targets
	Results []struct {
		// Target hostname or IP address
		Target string `json:"target" example:"192.168.1.1"`
		// Whether the test was successful
		Success bool `json:"success" example:"true"`
		// Error message if test failed
		Error *string `json:"error" example:"connection refused"`
		// Performance test summary results
		Summary struct {
			// Network throughput in bits per second
			BitsPerSecond float64 `json:"bits_per_second" example:"943215000"`
			// Total bytes received during the test
			BytesReceived int64 `json:"bytes_received" example:"12582912"`
			// Total bytes sent during the test
			BytesSent int64 `json:"bytes_sent" example:"12582912"`
			// Test duration in seconds
			Duration float64 `json:"duration" example:"10.05"`
			// Network jitter in milliseconds
			JitterMs float64 `json:"jitter_ms" example:"0.85"`
			// Percentage of packets lost during the test
			LossPercent float64 `json:"loss_percent" example:"0.02"`
			// Number of packets lost during the test
			PacketsLost int64 `json:"packets_lost" example:"2"`
			// Number of packets received during the test
			PacketsReceived int64 `json:"packets_received" example:"9998"`
			// Number of packets sent during the test
			PacketsSent int64 `json:"packets_sent" example:"10000"`
		} `json:"summary"`
	} `json:"results"`
	// ISO8601 timestamp when data was collected
	Timestamp string `json:"timestamp" example:"2025-04-24T14:15:22Z"`
}

// RperfMetrics represents processed network performance metrics.
// @Description Processed network performance metrics from rperf tests.
type RperfMetrics struct {
	// Array of performance metrics for different targets
	Results []RperfMetric `json:"results"`
}

// RperfMetric represents a single network performance test result.
// @Description Single network performance test result for a specific target.
type RperfMetric struct {
	// When the test was performed
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// Test name or identifier
	Name string `json:"name" example:"rperf_tcp_test"`
	// Network throughput in bits per second
	BitsPerSecond float64 `json:"bits_per_second" example:"943215000"`
	// Total bytes received during the test
	BytesReceived int64 `json:"bytes_received" example:"12582912"`
	// Total bytes sent during the test
	BytesSent int64 `json:"bytes_sent" example:"12582912"`
	// Test duration in seconds
	Duration float64 `json:"duration" example:"10.05"`
	// Network jitter in milliseconds
	JitterMs float64 `json:"jitter_ms" example:"0.85"`
	// Percentage of packets lost during the test
	LossPercent float64 `json:"loss_percent" example:"0.02"`
	// Number of packets lost during the test
	PacketsLost int64 `json:"packets_lost" example:"2"`
	// Number of packets received during the test
	PacketsReceived int64 `json:"packets_received" example:"9998"`
	// Number of packets sent during the test
	PacketsSent int64 `json:"packets_sent" example:"10000"`
	// Whether the test was successful
	Success bool `json:"success" example:"true"`
	// Target hostname or IP address
	Target string `json:"target" example:"192.168.1.1"`
	// Error message if test failed (null if successful)
	Error *string `json:"error,omitempty" example:"connection refused"`
}

// RperfMetricResponse represents the API response for rperf metrics.
// @Description API response containing rperf metrics data.
type RperfMetricResponse struct {
	// Array of performance metrics
	Metrics []RperfMetric `json:"metrics"`
	// Error information if retrieval failed (not serialized)
	Err error `json:"-"`
}
