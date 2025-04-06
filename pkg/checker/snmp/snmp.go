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

package snmp

import (
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

// SNMPMetricsManager implements the SNMPManager interface for handling SNMP metrics.
type SNMPMetricsManager struct {
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance.
func NewSNMPManager(db db.Service) SNMPManager {
	return &SNMPMetricsManager{
		db: db,
	}
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given poller.
func (s *SNMPMetricsManager) GetSNMPMetrics(pollerID string, startTime, endTime time.Time) ([]db.SNMPMetric, error) {
	log.Printf("Fetching SNMP metrics for poller %s from %v to %v", pollerID, startTime, endTime)

	query := `
        SELECT 
            metric_name as oid_name,  -- Map metric_name to oid_name
            value,
            metric_type as value_type,
            timestamp,
            COALESCE(
                json_extract(metadata, '$.scale'),
                1.0
            ) as scale,
            COALESCE(
                json_extract(metadata, '$.is_delta'),
                0
            ) as is_delta
        FROM timeseries_metrics
        WHERE poller_id = ? 
        AND metric_type = 'snmp' 
        AND timestamp BETWEEN ? AND ?
    `

	rows, err := s.db.Query(query, pollerID, startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query SNMP metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var metrics []db.SNMPMetric

	for rows.Next() {
		var metric db.SNMPMetric
		if err := rows.Scan(
			&metric.OIDName,
			&metric.Value,
			&metric.ValueType,
			&metric.Timestamp,
			&metric.Scale,
			&metric.IsDelta,
		); err != nil {
			return nil, fmt.Errorf("failed to scan SNMP metric: %w", err)
		}

		metrics = append(metrics, metric)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	log.Printf("Retrieved %d SNMP metrics for poller %s", len(metrics), pollerID)

	return metrics, nil
}
