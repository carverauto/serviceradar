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
		return errRperfMetricNil
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

		if err := json.Unmarshal([]byte(tsMetrics[i].Metadata), &rperfMetric); err != nil {
			log.Printf("Failed to unmarshal rperf metadata for metric %s on poller %s: %v", tsMetrics[i].Name, pollerID, err)
			continue
		}

		rperfMetric.Timestamp = tsMetrics[i].Timestamp // Ensure timestamp is set
		rperfMetrics = append(rperfMetrics, &rperfMetric)
	}

	log.Printf("Retrieved %d rperf metrics for poller %s", len(rperfMetrics), pollerID)

	return rperfMetrics, nil
}
