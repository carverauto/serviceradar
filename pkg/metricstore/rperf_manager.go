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

// Package metricstore pkg/metricstore/rperf_manager.go
package metricstore

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

type rperfManagerImpl struct {
	db db.Service
}

// NewRperfManager creates a new RperfManager instance.
func NewRperfManager(d db.Service) RperfManager {
	return &rperfManagerImpl{db: d}
}

const (
	rperfBitsPerSecondDivisor = 1e6 // To convert bps to Mbps
)

// StoreRperfMetric stores an rperf metric in the database.
func (m *rperfManagerImpl) StoreRperfMetric(
	ctx context.Context, pollerID string, rperfResult *models.RperfMetric, timestamp time.Time) error {
	if rperfResult == nil {
		return fmt.Errorf("rperf metric is nil")
	}

	if !rperfResult.Success {
		log.Printf("Skipping metrics storage for failed rperf test (Target: %s) on poller %s. Error: %v",
			rperfResult.Target, pollerID, rperfResult.Error)
		return nil
	}

	// Marshal the RperfMetric as metadata
	metadataBytes, err := json.Marshal(rperfResult)
	if err != nil {
		return fmt.Errorf("failed to marshal rperf result metadata for poller %s, target %s: %w",
			pollerID, rperfResult.Target, err)
	}

	metadataStr := string(metadataBytes)

	metricsToStore := []*models.TimeseriesMetric{
		{
			Name:      fmt.Sprintf("rperf_%s_bandwidth_mbps", rperfResult.Target),
			Value:     fmt.Sprintf("%.2f", rperfResult.BitsPerSec/rperfBitsPerSecondDivisor),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataStr,
		},
		{
			Name:      fmt.Sprintf("rperf_%s_jitter_ms", rperfResult.Target),
			Value:     fmt.Sprintf("%.2f", rperfResult.JitterMs),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataStr,
		},
		{
			Name:      fmt.Sprintf("rperf_%s_loss_percent", rperfResult.Target),
			Value:     fmt.Sprintf("%.1f", rperfResult.LossPercent),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataStr,
		},
		{
			Name:      fmt.Sprintf("rperf_%s_response_time_ns", rperfResult.Target),
			Value:     fmt.Sprintf("%d", rperfResult.ResponseTime),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataStr,
		},
	}

	if err := m.db.StoreMetrics(ctx, pollerID, metricsToStore); err != nil {
		return fmt.Errorf("failed to store rperf metrics for poller %s, target %s: %w",
			pollerID, rperfResult.Target, err)
	}

	log.Printf("Stored %d rperf metrics for poller %s, target %s", len(metricsToStore), pollerID, rperfResult.Target)

	return nil
}

// parseFloat64Field parses a string field into a float64 value.
func parseFloat64Field(value string) (float64, error) {
	if value == "" {
		return 0, fmt.Errorf("empty value")
	}

	return strconv.ParseFloat(value, 64)
}

// parseInt64Field parses a string field into an int64 value.
func parseInt64Field(value string) (int64, error) {
	if value == "" {
		return 0, fmt.Errorf("empty value")
	}

	return strconv.ParseInt(value, 10, 64)
}

// parseLegacyRperfMetadata attempts to parse legacy string-based metadata into an RperfMetric.
func parseLegacyRperfMetadata(metricName, pollerID, metadataStr string) (*models.RperfMetric, bool) {
	var legacyMetadata map[string]string

	if err := json.Unmarshal([]byte(metadataStr), &legacyMetadata); err != nil {
		log.Printf("Warning: failed to unmarshal legacy rperf metadata for metric %s on poller %s: %v", metricName, pollerID, err)
		return nil, false
	}

	var rperfMetric models.RperfMetric

	// Parse string fields
	rperfMetric.Target = legacyMetadata["target"]
	rperfMetric.Success = legacyMetadata["success"] == "true"

	if legacyMetadata["error"] != "" {
		errStr := legacyMetadata["error"]
		rperfMetric.Error = &errStr
	}

	// Parse required float64 field
	bitsPerSec, err := parseFloat64Field(legacyMetadata["bits_per_second"])
	if err != nil {
		log.Printf("Warning: invalid bits_per_second in legacy metadata for metric %s: %v", metricName, err)
		return nil, false
	}

	rperfMetric.BitsPerSec = bitsPerSec

	// Parse optional float64 fields
	if val, err := parseFloat64Field(legacyMetadata["duration"]); err == nil {
		rperfMetric.Duration = val
	}

	if val, err := parseFloat64Field(legacyMetadata["jitter_ms"]); err == nil {
		rperfMetric.JitterMs = val
	}

	if val, err := parseFloat64Field(legacyMetadata["loss_percent"]); err == nil {
		rperfMetric.LossPercent = val
	}

	// Parse optional int64 fields
	if val, err := parseInt64Field(legacyMetadata["bytes_received"]); err == nil {
		rperfMetric.BytesReceived = val
	}

	if val, err := parseInt64Field(legacyMetadata["bytes_sent"]); err == nil {
		rperfMetric.BytesSent = val
	}

	if val, err := parseInt64Field(legacyMetadata["packets_lost"]); err == nil {
		rperfMetric.PacketsLost = val
	}

	if val, err := parseInt64Field(legacyMetadata["packets_received"]); err == nil {
		rperfMetric.PacketsReceived = val
	}

	if val, err := parseInt64Field(legacyMetadata["packets_sent"]); err == nil {
		rperfMetric.PacketsSent = val
	}

	if val, err := parseInt64Field(legacyMetadata["response_time"]); err == nil {
		rperfMetric.ResponseTime = val
	}

	// Set optional string fields
	rperfMetric.AgentID = legacyMetadata["agent_id"]
	rperfMetric.ServiceName = legacyMetadata["service_name"]
	rperfMetric.ServiceType = legacyMetadata["service_type"]
	rperfMetric.Version = legacyMetadata["version"]

	return &rperfMetric, true
}

// GetRperfMetrics retrieves rperf metrics for a poller within a time range.
func (m *rperfManagerImpl) GetRperfMetrics(
	ctx context.Context, pollerID string, startTime, endTime time.Time) ([]*models.RperfMetric, error) {
	log.Printf("Fetching rperf metrics for poller %s from %v to %v", pollerID, startTime, endTime)

	tsMetrics, err := m.db.GetMetricsByType(ctx, pollerID, "rperf", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query rperf timeseries metrics: %w", err)
	}

	rperfMetrics := make([]*models.RperfMetric, 0, len(tsMetrics))

	for i := range tsMetrics {
		if tsMetrics[i].Metadata == "" {
			log.Printf("Warning: empty metadata for rperf metric %s on poller %s", tsMetrics[i].Name, pollerID)
			continue
		}

		var rperfMetric models.RperfMetric

		if err := json.Unmarshal([]byte(tsMetrics[i].Metadata), &rperfMetric); err == nil {
			rperfMetric.Timestamp = tsMetrics[i].Timestamp // Ensure timestamp is set
			rperfMetrics = append(rperfMetrics, &rperfMetric)

			continue
		}

		log.Printf("Failed to unmarshal rperf metadata for metric %s on poller %s, attempting legacy parsing", tsMetrics[i].Name, pollerID)

		if parsedMetric, success := parseLegacyRperfMetadata(tsMetrics[i].Name, pollerID, tsMetrics[i].Metadata); success {
			parsedMetric.Timestamp = tsMetrics[i].Timestamp
			rperfMetrics = append(rperfMetrics, parsedMetric)
		}
	}

	log.Printf("Retrieved %d rperf metrics for poller %s", len(rperfMetrics), pollerID)

	return rperfMetrics, nil
}
