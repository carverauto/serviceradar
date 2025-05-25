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
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

// SNMPMetricsManager implements the SNMPManager interface for handling SNMP metrics.
type SNMPMetricsManager struct {
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance.
func NewSNMPManager(d db.Service) SNMPManager {
	return &SNMPMetricsManager{
		db: d,
	}
}

// parseMetadata extracts a map from a JSON string metadata
func parseMetadata(metadataStr, metricName, pollerID string) (map[string]interface{}, bool) {
	if metadataStr == "" {
		log.Printf("Warning: empty metadata for metric %s on poller %s", metricName, pollerID)
		return nil, false
	}

	var metadata map[string]interface{}

	if err := json.Unmarshal([]byte(metadataStr), &metadata); err != nil {
		log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", metricName, pollerID, err)
		return nil, false
	}

	return metadata, true
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given poller.
func (s *SNMPMetricsManager) GetSNMPMetrics(
	ctx context.Context, pollerID string, startTime, endTime time.Time) ([]models.SNMPMetric, error) {
	log.Printf("Fetching SNMP metrics for poller %s from %v to %v", pollerID, startTime, endTime)

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
