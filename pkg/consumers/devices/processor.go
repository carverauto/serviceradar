package devices

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/nats-io/nats.go/jetstream"
)

var (
	ErrEmptyMessage = errors.New("empty message received")
	ErrUnmarshal    = errors.New("failed to unmarshal device")
	ErrStoreDevice  = errors.New("failed to store device")
)

type Processor struct {
	db       db.Service
	agentID  string
	pollerID string
}

func NewProcessor(agentID, pollerID string, dbService db.Service) *Processor {
	return &Processor{db: dbService, agentID: agentID, pollerID: pollerID}
}

// prepareDevice converts a JetStream message into a Device model.
func (p *Processor) prepareDevice(msg jetstream.Msg) (*models.Device, error) {
	data := msg.Data()

	if len(data) == 0 {
		return nil, ErrEmptyMessage
	}

	// Attempt to unmarshal into SweepResult first. If successful, convert it to
	// a Device. This supports events from discovery integrations that publish
	// SweepResult messages instead of full Device records.
	var sweep models.SweepResult

	if err := json.Unmarshal(data, &sweep); err == nil && sweep.IP != "" {
		device := p.convertSweepResultToDevice(&sweep)
		return device, nil
	}

	// Fall back to unmarshalling directly into Device for backward compatibility
	var device models.Device

	if err := json.Unmarshal(data, &device); err != nil {
		log.Printf("Failed to unmarshal device: %v", err)
		return nil, ErrUnmarshal
	}

	p.setDeviceDefaults(&device)

	return &device, nil
}

// convertSweepResultToDevice converts a SweepResult to a Device.
func (p *Processor) convertSweepResultToDevice(sweep *models.SweepResult) *models.Device {
	device := &models.Device{
		DeviceID:         "",
		AgentID:          sweep.AgentID,
		PollerID:         sweep.PollerID,
		DiscoverySources: []string{sweep.DiscoverySource},
		IP:               sweep.IP,
		MAC:              "",
		Hostname:         "",
		FirstSeen:        sweep.Timestamp,
		LastSeen:         sweep.Timestamp,
		IsAvailable:      sweep.Available,
		Metadata:         make(map[string]interface{}),
	}

	if sweep.MAC != nil {
		device.MAC = *sweep.MAC
	}

	if sweep.Hostname != nil {
		device.Hostname = *sweep.Hostname
	}

	if sweep.Partition != "" {
		device.DeviceID = fmt.Sprintf("%s:%s", sweep.Partition, sweep.IP)
	}

	for k, v := range sweep.Metadata {
		device.Metadata[k] = v
	}

	// Add discovery source to metadata for downstream processing
	device.Metadata["discovery_source"] = sweep.DiscoverySource

	p.setDeviceDefaults(device)

	// Set DeviceID if it's still empty after applying defaults
	if device.DeviceID == "" {
		device.DeviceID = fmt.Sprintf("%s:%s", sweep.Partition, sweep.IP)
	}

	return device
}

// setDeviceDefaults sets default values for a Device.
func (p *Processor) setDeviceDefaults(device *models.Device) {
	if device.AgentID == "" {
		device.AgentID = p.agentID
	}

	if device.PollerID == "" {
		device.PollerID = p.pollerID
	}

	// If timestamp is zero, set to now for both fields.
	if device.FirstSeen.IsZero() {
		device.FirstSeen = time.Now()
	}

	device.LastSeen = time.Now()
}

// storeBatch persists a slice of devices using the modern sweep results pipeline.
func (p *Processor) storeBatch(ctx context.Context, devices []*models.Device) error {
	if len(devices) == 0 {
		return nil
	}

	// Convert devices to sweep results for the materialized view pipeline
	var sweepResults []*models.SweepResult
	for _, device := range devices {
		// Convert metadata from interface{} to map[string]string
		metadata := make(map[string]string)
		for k, v := range device.Metadata {
			if strVal, ok := v.(string); ok {
				metadata[k] = strVal
			}
		}

		// Create sweep result from device
		sweep := &models.SweepResult{
			AgentID:         device.AgentID,
			PollerID:        device.PollerID,
			Partition:       extractPartitionFromDeviceID(device.DeviceID),
			DiscoverySource: extractDiscoverySource(device.DiscoverySources),
			IP:              device.IP,
			Timestamp:       device.LastSeen,
			Available:       device.IsAvailable,
			Metadata:        metadata,
		}

		// Set hostname if present
		if device.Hostname != "" {
			sweep.Hostname = &device.Hostname
		}

		// Set MAC if present
		if device.MAC != "" {
			sweep.MAC = &device.MAC
		}

		sweepResults = append(sweepResults, sweep)
	}

	// Use the materialized view pipeline
	if err := p.db.PublishBatchSweepResults(ctx, sweepResults); err != nil {
		log.Printf("Failed to publish sweep results: %v", err)
		return ErrStoreDevice
	}

	return nil
}

// extractPartitionFromDeviceID extracts the partition from a device ID (format: partition:ip)
func extractPartitionFromDeviceID(deviceID string) string {
	if deviceID == "" {
		return "default"
	}

	// Split on first colon to get partition
	for i, c := range deviceID {
		if c == ':' {
			return deviceID[:i]
		}
	}

	return "default"
}

// extractDiscoverySource gets the primary discovery source from the sources list
func extractDiscoverySource(sources []string) string {
	if len(sources) == 0 {
		return "device-consumer"
	}
	return sources[0]
}

// Process converts and stores a single JetStream message.
func (p *Processor) Process(ctx context.Context, msg jetstream.Msg) error {
	device, err := p.prepareDevice(msg)
	if err != nil {
		return err
	}

	if err := p.storeBatch(ctx, []*models.Device{device}); err != nil {
		log.Printf("Failed to store device %s: %v", device.DeviceID, err)
		return err
	}

	return nil
}

// ProcessBatch processes multiple JetStream messages in one database batch.
func (p *Processor) ProcessBatch(ctx context.Context, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	if len(msgs) == 0 {
		return nil, nil
	}

	devices := make([]*models.Device, 0, len(msgs))
	processed := make([]jetstream.Msg, 0, len(msgs))

	for _, msg := range msgs {
		device, err := p.prepareDevice(msg)
		if err != nil {
			return processed, err
		}

		devices = append(devices, device)
		processed = append(processed, msg)
	}

	if err := p.storeBatch(ctx, devices); err != nil {
		return processed, err
	}

	return processed, nil
}
