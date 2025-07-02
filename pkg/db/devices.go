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
	query := fmt.Sprintf(`SELECT
        device_id, agent_id, poller_id, discovery_sources, ip, mac, hostname,
        first_seen, last_seen, is_available, metadata
    FROM table(unified_devices)
    WHERE ip = '%s'`, ip)

	rows, err := db.Conn.Query(ctx, query)
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
			&d.DiscoverySources,
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
	query := fmt.Sprintf(`SELECT
        device_id, agent_id, poller_id, discovery_sources, ip, mac, hostname,
        first_seen, last_seen, is_available, metadata
    FROM table(unified_devices)
    WHERE device_id = '%s'
    LIMIT 1`, deviceID)

	rows, err := db.Conn.Query(ctx, query)
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
		&d.DiscoverySources,
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

// StoreDevices is deprecated - use StoreUnifiedDevice instead
// This method is kept for backward compatibility but should not be used
func (db *DB) StoreDevices(ctx context.Context, devices []*models.Device) error {
	// Special handling for integration devices coming from device consumer
	// Convert them to device updates and process through registry
	for _, device := range devices {
		// Check if this is an integration device by looking at metadata
		isIntegrationDevice := false
		discoverySource := ""
		if device.Metadata != nil {
			if source, ok := device.Metadata["discovery_source"]; ok {
				if sourceStr, ok := source.(string); ok {
					if sourceStr == "netbox" || sourceStr == "armis" || sourceStr == "integration" {
						isIntegrationDevice = true
						discoverySource = sourceStr
					}
				}
			}
		}
		
		if isIntegrationDevice {
			log.Printf("Processing %s device %s through device registry", discoverySource, device.DeviceID)
			// Note: We cannot use the device registry directly here because this is the database layer
			// and the device registry lives in a higher layer. For now, store directly to the database
			// but log that this should be handled differently in the future.
			// TODO: Refactor to have integration devices go through proper device registry flow
			
			// Map the discovery source to the appropriate constant
			var source models.DiscoverySource
			switch discoverySource {
			case "netbox":
				source = models.DiscoverySourceIntegration // Use "integration" as the category
			case "armis":
				source = models.DiscoverySourceIntegration // Use "integration" as the category  
			default:
				source = models.DiscoverySourceIntegration
			}
			
			// Convert to UnifiedDevice with specific source information
			unifiedDevice := &models.UnifiedDevice{
				DeviceID:    device.DeviceID,
				IP:          device.IP,
				FirstSeen:   device.FirstSeen,
				LastSeen:    device.LastSeen,
				IsAvailable: device.IsAvailable,
			}
			
			// Convert metadata and preserve specific integration source
			stringMetadata := make(map[string]string)
			for k, v := range device.Metadata {
				if str, ok := v.(string); ok {
					stringMetadata[k] = str
				} else {
					stringMetadata[k] = fmt.Sprintf("%v", v)
				}
			}
			// Store the specific integration type in metadata for UI display
			stringMetadata["integration_type"] = discoverySource
			
			// Set hostname field if available
			if device.Hostname != "" {
				unifiedDevice.Hostname = &models.DiscoveredField[string]{
					Value:       device.Hostname,
					Source:      source,
					Confidence:  10, // High confidence for integration data
					LastUpdated: device.LastSeen,
					AgentID:     device.AgentID,
					PollerID:    device.PollerID,
				}
			}
			
			// Set MAC field if available
			if device.MAC != "" {
				unifiedDevice.MAC = &models.DiscoveredField[string]{
					Value:       device.MAC,
					Source:      source,
					Confidence:  10, // High confidence for integration data
					LastUpdated: device.LastSeen,
					AgentID:     device.AgentID,
					PollerID:    device.PollerID,
				}
			}
			
			// Set metadata field
			unifiedDevice.Metadata = &models.DiscoveredField[map[string]string]{
				Value:       stringMetadata,
				Source:      source,
				Confidence:  10,
				LastUpdated: device.LastSeen,
				AgentID:     device.AgentID,
				PollerID:    device.PollerID,
			}
			
			// Set discovery sources with specific integration type
			unifiedDevice.DiscoverySources = []models.DiscoverySourceInfo{
				{
					Source:     source,
					AgentID:    device.AgentID,
					PollerID:   device.PollerID,
					LastSeen:   device.LastSeen,
					Confidence: 10,
				},
			}
			
			// Store in unified device registry
			if err := db.StoreUnifiedDevice(ctx, unifiedDevice); err != nil {
				log.Printf("Failed to store %s device %s in unified registry: %v", discoverySource, device.DeviceID, err)
				return err
			}
			
			log.Printf("Successfully stored %s device %s in unified registry", discoverySource, device.DeviceID)
		}
	}
	
	// Silent no-op for non-integration devices to prevent legacy publishing
	return nil
}
