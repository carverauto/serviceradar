package db

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// GetDevicesByIP retrieves devices with a specific IP address.
func (db *DB) GetDevicesByIP(ctx context.Context, ip string) ([]*models.Device, error) {
	unified, err := db.GetUnifiedDevicesByIP(ctx, ip)
	if err != nil {
		return nil, err
	}

	devices := make([]*models.Device, 0, len(unified))
	for _, ud := range unified {
		if ud == nil {
			continue
		}
		devices = append(devices, ud.ToLegacyDevice())
	}

	return devices, nil
}

// GetDeviceByID retrieves a device by its ID.
func (db *DB) GetDeviceByID(ctx context.Context, deviceID string) (*models.Device, error) {
	ud, err := db.GetUnifiedDevice(ctx, deviceID)
	if err != nil {
		return nil, err
	}

	return ud.ToLegacyDevice(), nil
}
