package db

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFailedToScanDeviceRow = errors.New("failed to scan device row")
	errIterRows              = errors.New("error iterating rows")
	errDeviceNotFound        = errors.New("device not found")
	errFailedMarshalMetadata = errors.New("failed to marshal metadata")
	errFailedStoreDevice     = errors.New("failed to store device")
	errFailedToPrepareBatch  = errors.New("failed to prepare batch")
	errFailedToSendBatch     = errors.New("failed to send batch")
	errFailedToQueryDevice   = errors.New("failed to query device")
)

func generateDeviceID(pollerID, ipAddress string) string {
	h := sha256.New()
	h.Write([]byte(pollerID + ":" + ipAddress))

	return base64.URLEncoding.EncodeToString(h.Sum(nil))
}

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
			return fmt.Errorf("%w: %w", errFailedMarshalMetadata, err)
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
		return fmt.Errorf("%w: %w", errFailedStoreDevice, err)
	}

	return nil
}

// prepareDeviceForStorage prepares a device for storage by setting default values and processing metadata.
// It returns the metadata as a string and a boolean indicating if the device should be skipped.
func prepareDeviceForStorage(device *models.Device) (string, bool) {
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
			log.Printf("Failed to marshal metadata for device %s: %v", device.IP, err)
			return "", true // Skip this device
		}

		metadataStr = string(metadataBytes)
	}

	return metadataStr, false // Don't skip this device
}

// StoreBatchDevices stores multiple devices in a single batch operation.
func (db *DB) StoreBatchDevices(ctx context.Context, devices []*models.Device) error {
	if len(devices) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO devices (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToPrepareBatch, err)
	}

	for _, device := range devices {
		metadataStr, skip := prepareDeviceForStorage(device)
		if skip {
			continue
		}

		err = batch.Append(
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
		)
		if err != nil {
			log.Printf("Failed to append device %s to batch: %v", device.IP, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w: %w", errFailedToSendBatch, err)
	}

	return nil
}

// GetDevicesByIP retrieves devices with a specific IP address.
func (db *DB) GetDevicesByIP(ctx context.Context, ip string) ([]*models.Device, error) {
	query := `SELECT 
        device_id, poller_id, discovery_source, ip, mac, hostname, 
        first_seen, last_seen, is_available, metadata 
    FROM table(devices)
    WHERE ip = ?`

	rows, err := db.Conn.Query(ctx, query, ip)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryDevice, err)
	}
	defer rows.Close()

	var devices []*models.Device

	for rows.Next() {
		var d models.Device

		var metadataStr string

		err := rows.Scan(
			&d.DeviceID,
			&d.PollerID,
			&d.DiscoverySource,
			&d.IP,
			&d.MAC,
			&d.Hostname,
			&d.FirstSeen,
			&d.LastSeen,
			&d.IsAvailable,
			&metadataStr,
		)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToScanDeviceRow, err)
		}

		if metadataStr != "" {
			if err := json.Unmarshal([]byte(metadataStr), &d.Metadata); err != nil {
				log.Printf("Warning: failed to unmarshal metadata for device %s: %v", d.DeviceID, err)
			}
		}

		devices = append(devices, &d)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %w", errIterRows, err)
	}

	return devices, nil
}

// GetDeviceByID retrieves a device by its ID.
func (db *DB) GetDeviceByID(ctx context.Context, deviceID string) (*models.Device, error) {
	query := `SELECT 
        device_id, poller_id, discovery_source, ip, mac, hostname, 
        first_seen, last_seen, is_available, metadata 
    FROM table(devices)
    WHERE device_id = ? 
    LIMIT 1`

	rows, err := db.Conn.Query(ctx, query, deviceID)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryDevice, err)
	}
	defer rows.Close()

	if !rows.Next() {
		return nil, fmt.Errorf("%w: %s", errDeviceNotFound, deviceID)
	}

	var d models.Device

	var metadataStr string

	err = rows.Scan(
		&d.DeviceID,
		&d.PollerID,
		&d.DiscoverySource,
		&d.IP,
		&d.MAC,
		&d.Hostname,
		&d.FirstSeen,
		&d.LastSeen,
		&d.IsAvailable,
		&metadataStr,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanDeviceRow, err)
	}

	if metadataStr != "" {
		if err := json.Unmarshal([]byte(metadataStr), &d.Metadata); err != nil {
			log.Printf("Warning: failed to unmarshal metadata for device %s: %v", d.DeviceID, err)
		}
	}

	return &d, nil
}
