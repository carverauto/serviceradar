package db

import (
	"fmt"
	"log"
	"time"
)

// Update CleanOldData in pkg/db/db.go

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
