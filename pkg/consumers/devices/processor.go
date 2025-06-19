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

func (p *Processor) Process(ctx context.Context, msg jetstream.Msg) error {
	data := msg.Data()
	if len(data) == 0 {
		return ErrEmptyMessage
	}
	var device models.Device
	if err := json.Unmarshal(data, &device); err != nil {
		log.Printf("Failed to unmarshal device: %v", err)
		return ErrUnmarshal
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
	if err := p.db.StoreDevices(ctx, []*models.Device{&device}); err != nil {
		log.Printf("Failed to store device %s: %v", device.DeviceID, err)
		return ErrStoreDevice
	}
	return nil
}
