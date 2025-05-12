package netflow

import (
	"context"
	"fmt"
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
	cfg       *NetflowConfig
	nc        *nats.Conn
	js        jetstream.JetStream
	consumer  *Consumer
	processor *Processor
	wg        sync.WaitGroup
	db        db.Service
}

// NewService creates a new NetFlow consumer service.
func NewService(cfg *NetflowConfig, dbService db.Service) (*Service, error) {
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
	log.Printf("NATS TLS paths: CertFile=%s, KeyFile=%s, CAFile=%s",
		s.cfg.Security.TLS.CertFile, s.cfg.Security.TLS.KeyFile, s.cfg.Security.TLS.CAFile)

	// Initialize netflow_metrics stream
	if err := s.initSchema(ctx); err != nil {
		return fmt.Errorf("failed to initialize netflow_metrics schema: %w", err)
	}

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

	// Verify stream configuration
	stream, err := js.Stream(ctx, s.cfg.StreamName)
	if err != nil {
		s.nc.Close()

		return fmt.Errorf("failed to get stream %s: %w", s.cfg.StreamName, err)
	}

	info, err := stream.Info(ctx)
	if err != nil {
		s.nc.Close()

		return fmt.Errorf("failed to get stream info: %w", err)
	}

	log.Printf("Stream %s config: Subjects=%v, Retention=%s, Messages=%d, LastSeq=%d",
		s.cfg.StreamName, info.Config.Subjects, info.Config.Retention, info.State.Msgs, info.State.LastSeq)

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
	_, cancel := context.WithTimeout(ctx, defaultShutdownTimeout)
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

// initSchema creates the netflow_metrics stream for Proton.
func (s *Service) initSchema(ctx context.Context) error {
	dbImpl, ok := s.db.(*db.DB)
	if !ok {
		return fmt.Errorf("db.Service is not *db.DB")
	}

	// Create a new stream with the correct types matching the protobuf definition
	createStream := `CREATE STREAM IF NOT EXISTS netflow_metrics (
        timestamp DateTime64(3) CODEC(DoubleDelta, LZ4),
        src_addr string CODEC(ZSTD(1)),
        dst_addr string CODEC(ZSTD(1)),
        src_port uint32,
        dst_port uint32,
        protocol uint32,
        bytes uint64 CODEC(T64, LZ4),
        packets uint64 CODEC(T64, LZ4),
        forwarding_status uint32,
        next_hop string CODEC(ZSTD(1)),
        sampler_address string CODEC(ZSTD(1)),
        src_as uint32 DEFAULT 0,
        dst_as uint32 DEFAULT 0,
        ip_tos uint32,
        vlan_id uint32,
        bgp_next_hop string CODEC(ZSTD(1)),
        metadata string
    ) ENGINE = Stream(1, 1, sip_hash64(src_addr))
    PARTITION BY date(timestamp)
    ORDER BY (src_addr, dst_addr, sampler_address, timestamp)
    SETTINGS mode='append'`

	log.Printf("Creating netflow_metrics stream with 32-bit integer types")

	if err := dbImpl.Conn.Exec(ctx, createStream); err != nil {
		return fmt.Errorf("failed to create netflow_metrics stream: %w", err)
	}

	log.Printf("Successfully created netflow_metrics stream")

	return nil
}

// Ensure Service implements lifecycle.Service
var _ lifecycle.Service = (*Service)(nil)
