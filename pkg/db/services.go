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
			status.Timestamp,   // timestamp
			status.PollerID,    // poller_id
			status.AgentID,     // agent_id
			status.ServiceName, // service_name
			status.ServiceType, // service_type
			status.Available,   // available
			"",                 // message
			status.Details,     // details
			status.Partition,   // partition
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
		status.Timestamp,   // timestamp
		status.PollerID,    // poller_id
		status.AgentID,     // agent_id
		status.ServiceName, // service_name
		status.ServiceType, // service_type
		status.Available,   // available
		"",                 // message
		status.Details,     // details
		status.Partition,   // partition
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
	defer db.CloseRows(rows)

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

// StoreServices stores information about monitored services in the services stream.
func (db *DB) StoreServices(ctx context.Context, services []*models.Service) error {
	if len(services) == 0 {
		return nil
	}

	// First try with regular map approach (original schema)
	if err := db.storeServicesWithMap(ctx, services); err == nil {
		return nil
	}

	// If that fails, try with JSONMap approach (new schema)
	return db.storeServicesWithJSON(ctx, services)
}

// storeServicesWithMap tries to store services using map[string]string config
func (db *DB) storeServicesWithMap(ctx context.Context, services []*models.Service) error {
	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO services (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, svc := range services {
		config := svc.Config
		if config == nil {
			config = map[string]string{}
		}

		if err := batch.Append(
			svc.Timestamp,  // timestamp
			svc.PollerID,   // poller_id
			svc.AgentID,    // agent_id
			svc.ServiceName, // service_name
			svc.ServiceType, // service_type
			config,         // config as map[string]string
			svc.Partition,  // partition
		); err != nil {
			return fmt.Errorf("failed to append service %s: %w", svc.ServiceName, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w services with map: %w", ErrFailedToInsert, err)
	}

	return nil
}

// storeServicesWithJSON tries to store services using JSONMap config
func (db *DB) storeServicesWithJSON(ctx context.Context, services []*models.Service) error {
	// First, let's try a simple test query to see if the table exists
	var count int
	if err := db.Conn.QueryRow(ctx, "SELECT count() FROM services LIMIT 1").Scan(&count); err != nil {
		return fmt.Errorf("services table doesn't exist or is inaccessible: %w", err)
	}

	// Try different SQL variations to see what works
	sqlStatements := []string{
		"INSERT INTO services (* except _tp_time)",
		"INSERT INTO services",
		"INSERT INTO services (timestamp, poller_id, agent_id, service_name, service_type, config, partition)",
	}

	var lastErr error
	for _, sql := range sqlStatements {
		batch, err := db.Conn.PrepareBatch(ctx, sql)
		if err != nil {
			lastErr = fmt.Errorf("failed to prepare batch with SQL '%s': %w", sql, err)
			continue
		}

		// Try to append just the first service to test
		if len(services) > 0 {
			svc := services[0]
			config := svc.Config
			if config == nil {
				config = map[string]string{}
			}
			
			jsonConfig := FromMap(config)

			if err := batch.Append(
				svc.Timestamp,  // timestamp
				svc.PollerID,   // poller_id
				svc.AgentID,    // agent_id
				svc.ServiceName, // service_name
				svc.ServiceType, // service_type
				jsonConfig,     // config as JSONMap
				svc.Partition,  // partition
			); err != nil {
				lastErr = fmt.Errorf("failed to append service %s with SQL '%s': %w", svc.ServiceName, sql, err)
				continue
			}

			// If we get here, this SQL works - use it for all services
			break
		}
	}

	if lastErr != nil {
		return lastErr
	}

	// If we get here, we found a working SQL statement, now process all services
	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO services (timestamp, poller_id, agent_id, service_name, service_type, config, partition)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, svc := range services {
		config := svc.Config
		if config == nil {
			config = map[string]string{}
		}
		
		jsonConfig := FromMap(config)

		if err := batch.Append(
			svc.Timestamp,  // timestamp
			svc.PollerID,   // poller_id
			svc.AgentID,    // agent_id
			svc.ServiceName, // service_name
			svc.ServiceType, // service_type
			jsonConfig,     // config as JSONMap
			svc.Partition,  // partition
		); err != nil {
			return fmt.Errorf("failed to append service %s: %w", svc.ServiceName, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w services with JSON: %w", ErrFailedToInsert, err)
	}

	return nil
}
