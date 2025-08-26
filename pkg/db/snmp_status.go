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

package db

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// GetDevicesWithRecentSNMPMetrics checks a list of device IDs and returns a map indicating
// which ones have recent SNMP metrics.
func (db *DB) GetDevicesWithRecentSNMPMetrics(ctx context.Context, deviceIDs []string) (map[string]bool, error) {
	if len(deviceIDs) == 0 {
		return make(map[string]bool), nil
	}

	// Create a placeholder string for the IN clause like ('id1', 'id2', 'id3')
	placeholders := make([]string, len(deviceIDs))

	for i, id := range deviceIDs {
		// Basic sanitization for safety, though parameters are preferred if driver supported it well here.
		sanitizedID := strings.ReplaceAll(id, "'", "''")
		placeholders[i] = fmt.Sprintf("'%s'", sanitizedID)
	}

	inClause := strings.Join(placeholders, ",")

	// Check for metrics within the last 15 minutes. This is a reasonable window
	// to determine if a device is actively reporting SNMP data.
	cutoffTime := time.Now().Add(-15 * time.Minute)

	query := fmt.Sprintf(`
		SELECT DISTINCT device_id
		FROM table(timeseries_metrics)
		WHERE metric_type = 'snmp'
		  AND device_id IN (%s)
		  AND timestamp > to_datetime('%s')
	`, inClause, cutoffTime.Format(time.RFC3339))

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query for recent snmp metrics: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	// Use a map (acting as a set) for efficient lookup
	foundIDs := make(map[string]bool)

	for rows.Next() {
		var deviceID string

		if err := rows.Scan(&deviceID); err != nil {
			return nil, fmt.Errorf("failed to scan device_id for snmp status: %w", err)
		}

		foundIDs[deviceID] = true
	}

	return foundIDs, rows.Err()
}
