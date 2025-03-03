/*-
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
	"fmt"
	"log"
	"time"
)

// CleanOldData removes old data from the database.
func (db *DB) CleanOldData(retentionPeriod time.Duration) error {
	cutoff := time.Now().Add(-retentionPeriod)

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToBeginTx, err)
	}

	defer func() {
		if err != nil {
			if rbErr := tx.Rollback(); rbErr != nil {
				log.Printf("failed to rollback: %v", rbErr)
			}

			return
		}

		err = tx.Commit()
	}()

	// Clean up node history
	if _, err := tx.Exec(
		"DELETE FROM node_history WHERE timestamp < ?",
		cutoff,
	); err != nil {
		return fmt.Errorf("%w node history %w", errFailedToClean, err)
	}

	// Clean up service status
	if _, err := tx.Exec(
		"DELETE FROM service_status WHERE timestamp < ?",
		cutoff,
	); err != nil {
		return fmt.Errorf("%w service status: %w", errFailedToClean, err)
	}

	// Clean up timeseries metrics
	if _, err := tx.Exec(
		"DELETE FROM timeseries_metrics WHERE timestamp < ?",
		cutoff,
	); err != nil {
		return fmt.Errorf("%w timeseries metrics: %w", errFailedToClean, err)
	}

	return nil
}
