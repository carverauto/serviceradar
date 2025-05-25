package db

import (
	"context"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/models"
)

// UpdateServiceStatuses updates multiple service statuses in a single batch.
func (db *DB) UpdateServiceStatuses(ctx context.Context, statuses []*models.ServiceStatus) error {
	if len(statuses) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO service_status (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, status := range statuses {
		err = batch.Append(
			status.PollerID,
			status.ServiceName,
			status.ServiceType,
			status.Available,
			status.Details,
			status.Timestamp,
			status.AgentID,
		)
		if err != nil {
			return fmt.Errorf("failed to append service status for %s: %w", status.ServiceName, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w service statuses: %w", ErrFailedToInsert, err)
	}

	return nil
}

// UpdateServiceStatus updates a service's status.
func (db *DB) UpdateServiceStatus(ctx context.Context, status *models.ServiceStatus) error {
	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO service_status (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		status.PollerID,
		status.ServiceName,
		status.ServiceType,
		status.Available,
		status.Details,
		status.Timestamp,
	)
	if err != nil {
		return fmt.Errorf("failed to append service status: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w service status: %w", ErrFailedToInsert, err)
	}

	return nil
}

// GetServiceHistory retrieves the recent history for a service.
func (db *DB) GetServiceHistory(ctx context.Context, pollerID, serviceName string, limit int) ([]models.ServiceStatus, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, available, details
		FROM table(service_status)
		WHERE poller_id = $1 AND service_name = $2
		ORDER BY timestamp DESC
		LIMIT $3`,
		pollerID, serviceName, limit)
	if err != nil {
		return nil, fmt.Errorf("%w service history: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var history []models.ServiceStatus

	for rows.Next() {
		var s models.ServiceStatus

		s.PollerID = pollerID
		s.ServiceName = serviceName

		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("%w service history row: %w", ErrFailedToScan, err)
		}

		history = append(history, s)
	}

	return history, nil
}
