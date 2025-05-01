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

package db

import (
	"context"
	"fmt"
	"time"
)

// CleanOldData removes old data from the database.
func (db *DB) CleanOldData(ctx context.Context, retentionPeriod time.Duration) error {
	cutoff := time.Now().Add(-retentionPeriod)

	tables := []string{
		"cpu_metrics",
		"disk_metrics",
		"memory_metrics",
		"poller_history",
		"service_status",
		"timeseries_metrics",
	}

	for _, table := range tables {
		query := fmt.Sprintf("DELETE FROM %s WHERE timestamp < $1", table)
		if err := db.conn.Exec(ctx, query, cutoff); err != nil {
			return fmt.Errorf("%w %s: %w", ErrFailedToClean, table, err)
		}
	}

	return nil
}
