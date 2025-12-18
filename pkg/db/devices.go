package db

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// GetDevicesByIP retrieves devices with a specific IP address.
func (db *DB) GetDevicesByIP(ctx context.Context, ip string) ([]*models.Device, error) {
	ocsf, err := db.GetOCSFDevicesByIP(ctx, ip)
	if err != nil {
		return nil, err
	}

	devices := make([]*models.Device, 0, len(ocsf))
	for _, od := range ocsf {
		if od == nil {
			continue
		}
		devices = append(devices, od.ToLegacyDevice())
	}

	return devices, nil
}

// GetDeviceByID retrieves a device by its ID.
func (db *DB) GetDeviceByID(ctx context.Context, deviceID string) (*models.Device, error) {
	od, err := db.GetOCSFDevice(ctx, deviceID)
	if err != nil {
		return nil, err
	}

	return od.ToLegacyDevice(), nil
}
