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

// Package db pkg/db/sweep.go
package db

import (
	"context"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (db *DB) StoreSweepResults(ctx context.Context, results []*models.SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO sweep_results (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, result := range results {
		// Validate required fields
		if result.IP == "" {
			log.Printf("Skipping sweep result with empty IP for poller %s", result.PollerID)
			continue
		}

		if result.AgentID == "" {
			log.Printf("Skipping sweep result with empty AgentID for IP %s", result.IP)
			continue
		}

		if result.PollerID == "" {
			log.Printf("Skipping sweep result with empty PollerID for IP %s", result.IP)
			continue
		}

		// Ensure Metadata is a map[string]string; use empty map if nil
		metadata := result.Metadata
		if metadata == nil {
			metadata = make(map[string]string)
		}

		err = batch.Append(
			result.AgentID,
			result.PollerID,
			result.Partition,
			result.DiscoverySource,
			result.IP,
			result.MAC,
			result.Hostname,
			result.Timestamp,
			result.Available,
			metadata, // Pass map[string]string directly
		)
		if err != nil {
			log.Printf("Failed to append sweep result for IP %s: %v", result.IP, err)
			continue
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	log.Printf("Successfully stored %d sweep results", len(results))

	return nil
}
