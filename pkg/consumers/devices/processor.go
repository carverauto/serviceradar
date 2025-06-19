package devices

import (
	"context"
	"encoding/json"
	"errors"
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

	var device models.Device
	if err := json.Unmarshal(data, &device); err != nil {
		log.Printf("Failed to unmarshal device: %v", err)
		return nil, ErrUnmarshal
	}

	if device.AgentID == "" {
		device.AgentID = p.agentID
	}

	if device.PollerID == "" {
		device.PollerID = p.pollerID
	}

	if device.FirstSeen.IsZero() {
		device.FirstSeen = time.Now()
	}

	device.LastSeen = time.Now()

	return &device, nil
}

// storeBatch persists a slice of devices using the DB service.
func (p *Processor) storeBatch(ctx context.Context, devices []*models.Device) error {
	if len(devices) == 0 {
		return nil
	}

	if err := p.db.StoreDevices(ctx, devices); err != nil {
		return ErrStoreDevice
	}

	return nil
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
