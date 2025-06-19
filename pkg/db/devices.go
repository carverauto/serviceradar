package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFailedToScanDeviceRow = errors.New("failed to scan device row")
	errIterRows              = errors.New("error iterating rows")
	errDeviceNotFound        = errors.New("device not found")
	errFailedToQueryDevice   = errors.New("failed to query device")
)

// GetDevicesByIP retrieves devices with a specific IP address.
func (db *DB) GetDevicesByIP(ctx context.Context, ip string) ([]*models.Device, error) {
	query := `SELECT
        device_id, agent_id, poller_id, discovery_source, ip, mac, hostname,
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
			&d.AgentID,
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
        device_id, agent_id, poller_id, discovery_source, ip, mac, hostname,
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
		&d.AgentID,
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

// StoreDevices stores a batch of devices into the devices stream.
func (db *DB) StoreDevices(ctx context.Context, devices []*models.Device) error {
	if len(devices) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO devices (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, d := range devices {
		meta := make(map[string]string)
		for k, v := range d.Metadata {
			meta[k] = fmt.Sprintf("%v", v)
		}

		if err := batch.Append(
			d.DeviceID,
			d.AgentID,
			d.PollerID,
			d.DiscoverySource,
			d.IP,
			d.MAC,
			d.Hostname,
			d.FirstSeen,
			d.LastSeen,
			d.IsAvailable,
			meta,
		); err != nil {
			log.Printf("Failed to append device %s: %v", d.DeviceID, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	return nil
}
