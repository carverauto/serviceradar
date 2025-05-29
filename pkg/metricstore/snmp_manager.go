/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package metricstore pkg/metricstore/snmp_manager.go
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

type snmpManagerImpl struct {
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance.
func NewSNMPManager(d db.Service) SNMPManager {
	return &snmpManagerImpl{
		db: d,
	}
}

// parseMetadata extracts a map from a JSON string metadata.
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

// StoreSNMPMetric stores an SNMP metric in the database.
func (s *snmpManagerImpl) StoreSNMPMetric(
	ctx context.Context, pollerID string, metric *models.SNMPMetric, timestamp time.Time) error {
	if metric == nil {
		return fmt.Errorf("SNMP metric is nil")
	}

	// Validate required fields
	if metric.OIDName == "" {
		return fmt.Errorf("SNMP metric OIDName is empty")
	}

	if metric.ValueType == "" {
		return fmt.Errorf("SNMP metric ValueType is empty")
	}

	// Convert Value to string
	valueStr := fmt.Sprintf("%v", metric.Value)

	// Marshal the original SNMPMetric as metadata
	metadataBytes, err := json.Marshal(metric)
	if err != nil {
		return fmt.Errorf("failed to marshal SNMP metric metadata for poller %s, OID %s: %w",
			pollerID, metric.OIDName, err)
	}

	metadataStr := string(metadataBytes)

	// Create TimeseriesMetric
	tsMetric := &models.TimeseriesMetric{
		Name:      metric.OIDName,
		Value:     valueStr,
		Type:      "snmp",
		Timestamp: timestamp,
		Metadata:  metadataStr,
	}

	// Store using db.StoreMetric
	if err := s.db.StoreMetric(ctx, pollerID, tsMetric); err != nil {
		return fmt.Errorf("failed to store SNMP metric for poller %s, OID %s: %w",
			pollerID, metric.OIDName, err)
	}

	log.Printf("Stored SNMP metric for poller %s, OID %s", pollerID, metric.OIDName)

	return nil
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given poller.
func (s *snmpManagerImpl) GetSNMPMetrics(
	ctx context.Context, pollerID string, startTime, endTime time.Time) ([]models.SNMPMetric, error) {
	log.Printf("Fetching SNMP metrics for poller %s from %v to %v", pollerID, startTime, endTime)

	tsMetrics, err := s.db.GetMetricsByType(ctx, pollerID, "snmp", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query SNMP metrics: %w", err)
	}

	snmpMetrics := make([]models.SNMPMetric, 0, len(tsMetrics))

	for i := range tsMetrics {
		snmpMetric := models.SNMPMetric{
			OIDName:   tsMetrics[i].Name,
			Value:     tsMetrics[i].Value,
			ValueType: tsMetrics[i].Type,
			Timestamp: tsMetrics[i].Timestamp,
			Scale:     1.0, // Default value
			IsDelta:   false,
		}

		// Extract scale and is_delta from metadata
		metadata, ok := parseMetadata(tsMetrics[i].Metadata, tsMetrics[i].Name, pollerID)
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
