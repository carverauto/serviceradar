package db

import (
	"context"
	"errors"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errNoDeviceFilters = errors.New("no device filters provided")
)

// GetUnifiedDevice retrieves a unified device by its ID.
func (db *DB) GetUnifiedDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	return db.cnpgGetUnifiedDevice(ctx, deviceID)
}

// GetUnifiedDevicesByIP retrieves unified devices with a specific IP address.
func (db *DB) GetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	return db.cnpgGetUnifiedDevicesByIP(ctx, ip)
}

// ListUnifiedDevices returns a paginated list of unified devices.
func (db *DB) ListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	return db.cnpgListUnifiedDevices(ctx, limit, offset)
}

// CountUnifiedDevices returns the total number of unified devices.
func (db *DB) CountUnifiedDevices(ctx context.Context) (int64, error) {
	return db.cnpgCountUnifiedDevices(ctx)
}

// GetUnifiedDevicesByIPsOrIDs retrieves devices given lists of IPs/deviceIDs.
func (db *DB) GetUnifiedDevicesByIPsOrIDs(ctx context.Context, ips, deviceIDs []string) ([]*models.UnifiedDevice, error) {
	if len(ips) == 0 && len(deviceIDs) == 0 {
		return nil, errNoDeviceFilters
	}

	return db.cnpgQueryUnifiedDevicesBatch(ctx, deviceIDs, ips)
}
