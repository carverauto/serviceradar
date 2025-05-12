package db

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func generateDeviceID(pollerID, ipAddress string) string {
	h := sha256.New()
	h.Write([]byte(pollerID + ":" + ipAddress))

	return base64.URLEncoding.EncodeToString(h.Sum(nil))
}

var (
	errFailedMarshalMetadata = errors.New("failed to marshal metadata")
	errFailedStoreDevice     = errors.New("failed to store device")
)

// StoreDevice stores or updates a device in the database.
func (db *DB) StoreDevice(ctx context.Context, device *models.Device) error {
	if device.DeviceID == "" {
		device.DeviceID = generateDeviceID(device.PollerID, device.IP)
	}

	if device.LastSeen.IsZero() {
		device.LastSeen = time.Now()
	}

	if device.FirstSeen.IsZero() {
		device.FirstSeen = device.LastSeen
	}

	metadataStr := ""
	if device.Metadata != nil {
		metadataBytes, err := json.Marshal(device.Metadata)
		if err != nil {
			return fmt.Errorf("%w: %s", errFailedMarshalMetadata, err)
		}

		metadataStr = string(metadataBytes)
	}

	// For MergeTree tables, we can use the REPLACE INTO syntax to upsert
	query := `INSERT INTO devices (* except _tp_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	if err := db.Conn.Exec(ctx, query,
		device.DeviceID,
		device.PollerID,
		device.DiscoverySource,
		device.IP,
		device.MAC,
		device.Hostname,
		device.FirstSeen,
		device.LastSeen,
		device.IsAvailable,
		metadataStr,
	); err != nil {
		return fmt.Errorf("%w: %s", errFailedStoreDevice, err)
	}

	return nil
}
