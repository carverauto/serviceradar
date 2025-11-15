package db

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// UpdateServiceStatuses updates multiple service statuses using CNPG.
func (db *DB) UpdateServiceStatuses(ctx context.Context, statuses []*models.ServiceStatus) error {
	if len(statuses) == 0 {
		return nil
	}

	return db.cnpgInsertServiceStatuses(ctx, statuses)
}

// UpdateServiceStatus updates a single service status.
func (db *DB) UpdateServiceStatus(ctx context.Context, status *models.ServiceStatus) error {
	if status == nil {
		return nil
	}

	return db.cnpgInsertServiceStatuses(ctx, []*models.ServiceStatus{status})
}

// GetServiceHistory retrieves the recent history for a service.
func (db *DB) GetServiceHistory(ctx context.Context, pollerID, serviceName string, limit int) ([]models.ServiceStatus, error) {
	return db.cnpgGetServiceHistory(ctx, pollerID, serviceName, limit)
}

// StoreServices stores information about monitored services.
func (db *DB) StoreServices(ctx context.Context, services []*models.Service) error {
	return db.cnpgInsertServices(ctx, services)
}
