package netflow

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Service implements the lifecycle.Service interface for the NetFlow consumer.
type Service struct {
	cfg       Config
	nc        *nats.Conn
	js        jetstream.JetStream
	consumer  *Consumer
	processor *Processor
	wg        sync.WaitGroup
	db        db.Service
}

// NewService creates a new NetFlow consumer service.
func NewService(cfg Config, dbService db.Service) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	svc := &Service{
		cfg:       cfg,
		processor: NewProcessor(dbService, cfg),
		db:        dbService,
	}

	return svc, nil
}

// Start connects to NATS, initializes the consumer, and starts processing messages.
func (s *Service) Start(ctx context.Context) error {
	// Connect to NATS with mTLS
	nc, err := nats.Connect(s.cfg.NATSURL,
		nats.ClientCert(s.cfg.Security.TLS.CertFile, s.cfg.Security.TLS.KeyFile),
		nats.RootCAs(s.cfg.Security.TLS.CAFile),
	)
	if err != nil {
		return err
	}

	s.nc = nc

	// Initialize JetStream management interface
	js, err := jetstream.New(nc)
	if err != nil {
		s.nc.Close()
		return err
	}

	s.js = js

	// Create or get consumer
	s.consumer, err = NewConsumer(ctx, s.js, s.cfg.StreamName, s.cfg.ConsumerName)
	if err != nil {
		s.nc.Close()
		return err
	}

	// Start processing messages
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.consumer.ProcessMessages(ctx, s.processor)
	}()

	log.Printf("NetFlow consumer started for stream %s, consumer %s", s.cfg.StreamName, s.cfg.ConsumerName)
	return nil
}

const (
	defaultShutdownTimeout = 10 * time.Second
)

// Stop closes the NATS connection, database, and waits for processing to complete.
func (s *Service) Stop(ctx context.Context) error {
	// Set a timer for graceful shutdown
	ctx, cancel := context.WithTimeout(ctx, defaultShutdownTimeout)
	defer cancel()

	if s.db != nil {
		if err := s.db.Close(); err != nil {
			log.Printf("Failed to close database: %v", err)
		}
	}

	if s.nc != nil {
		s.nc.Close()
	}

	s.wg.Wait()
	log.Println("NetFlow consumer stopped")
	return nil
}

// Ensure Service implements lifecycle.Service
var _ lifecycle.Service = (*Service)(nil)
