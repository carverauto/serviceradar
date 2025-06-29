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

	insertQuery := `INSERT INTO service_status (
		service_name, service_type, available, details, timestamp, agent_id, partition
	)`
	batch, err := db.Conn.PrepareBatch(ctx, insertQuery)
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, status := range statuses {
		err = batch.Append(
			status.ServiceName,
			status.ServiceType,
			status.Available,
			status.Details,
			status.Timestamp,
			status.AgentID,
			status.Partition,
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
		status.AgentID,
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
func (db *DB) GetServiceHistory(ctx context.Context, agentID, serviceName string, limit int) ([]models.ServiceStatus, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, available, details
		FROM table(service_status)
		WHERE agent_id = $1 AND service_name = $2
		ORDER BY timestamp DESC
		LIMIT $3`,
		agentID, serviceName, limit)
	if err != nil {
		return nil, fmt.Errorf("%w service history: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var history []models.ServiceStatus

	for rows.Next() {
		var s models.ServiceStatus

		s.AgentID = agentID
		s.ServiceName = serviceName

		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("%w service history row: %w", ErrFailedToScan, err)
		}

		history = append(history, s)
	}

	return history, nil
}

// StoreServices stores information about monitored services in the services stream.
func (db *DB) StoreServices(ctx context.Context, services []*models.Service) error {
	if len(services) == 0 {
		return nil
	}

	insertQuery := `INSERT INTO services (
		agent_id, service_name, service_type, timestamp, partition
	)`
	batch, err := db.Conn.PrepareBatch(ctx, insertQuery)
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, svc := range services {
		if err := batch.Append(
			svc.AgentID,
			svc.ServiceName,
			svc.ServiceType,
			svc.Timestamp,
			svc.Partition,
		); err != nil {
			return fmt.Errorf("failed to append service %s: %w", svc.ServiceName, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w services: %w", ErrFailedToInsert, err)
	}

	return nil
}
