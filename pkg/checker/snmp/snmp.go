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

// Package snmp pkg/checker/snmp/snmp.go
package snmp

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// MetricsManager implements the SNMPManager interface for handling SNMP metrics.
type MetricsManager struct {
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance.
func NewSNMPManager(d db.Service) SNMPManager {
	return &MetricsManager{
		db: d,
	}
}

// parseMetadata extracts a map from a JSON string metadata
func parseMetadata(metadataStr, metricName, pollerID string) (map[string]interface{}, bool) {
	if metadataStr == "" {
		logger.Warn().
			Str("metric_name", metricName).
			Str("poller_id", pollerID).
			Msg("Empty metadata for metric")

		return nil, false
	}

	var metadata map[string]interface{}

	if err := json.Unmarshal([]byte(metadataStr), &metadata); err != nil {
		logger.Error().
			Err(err).
			Str("metric_name", metricName).
			Str("poller_id", pollerID).
			Msg("Failed to unmarshal metadata for metric")

		return nil, false
	}

	return metadata, true
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given poller.
func (s *MetricsManager) GetSNMPMetrics(
	ctx context.Context, pollerID string, startTime, endTime time.Time) ([]models.SNMPMetric, error) {
	logger.Info().
		Str("poller_id", pollerID).
		Time("start_time", startTime).
		Time("end_time", endTime).
		Msg("Fetching SNMP metrics")

	metrics, err := s.db.GetMetricsByType(ctx, pollerID, "snmp", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query SNMP metrics: %w", err)
	}

	snmpMetrics := make([]models.SNMPMetric, 0, len(metrics))

	for i := range metrics {
		snmpMetric := models.SNMPMetric{
			OIDName:   metrics[i].Name,
			Value:     metrics[i].Value,
			ValueType: metrics[i].Type,
			Timestamp: metrics[i].Timestamp,
			Scale:     1.0, // Default value
			IsDelta:   false,
		}

		// Extract scale and is_delta from metadata
		metadata, ok := parseMetadata(metrics[i].Metadata, metrics[i].Name, pollerID)
		if ok {
			if scale, ok := metadata["scale"].(float64); ok {
				snmpMetric.Scale = scale
			}

			if isDelta, ok := metadata["is_delta"].(bool); ok {
				snmpMetric.IsDelta = isDelta
			}
		}

		snmpMetrics = append(snmpMetrics, snmpMetric)
	}

	return snmpMetrics, nil
}
