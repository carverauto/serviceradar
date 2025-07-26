package dbeventwriter

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/natsutil"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Service implements lifecycle.Service for the DB event writer.
type Service struct {
	cfg       *DBEventWriterConfig
	nc        *nats.Conn
	js        jetstream.JetStream
	consumer  *Consumer
	processor *Processor
	wg        sync.WaitGroup
	db        db.Service
	logger    logger.Logger
}

// NewService initializes the service.
func NewService(cfg *DBEventWriterConfig, dbService db.Service, log logger.Logger) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	var proc *Processor

	var err error

	streams := cfg.GetStreams()
	if len(streams) > 0 {
		// Use new multi-stream configuration
		proc, err = NewProcessorWithStreams(dbService, streams, log)
	} else {
		// Legacy single stream configuration
		proc, err = NewProcessor(dbService, cfg.Table, log)
	}

	if err != nil {
		return nil, err
	}

	svc := &Service{cfg: cfg, processor: proc, db: dbService, logger: log}

	return svc, nil
}

// Start connects to NATS and begins processing messages.
func (s *Service) Start(ctx context.Context) error {
	var opts []nats.Option

	if s.cfg.Security != nil {
		tlsConf, err := natsutil.TLSConfig(s.cfg.Security)
		if err != nil {
			return fmt.Errorf("failed to build NATS TLS config: %w", err)
		}

		opts = append(opts,
			nats.Secure(tlsConf),
			nats.RootCAs(s.cfg.Security.TLS.CAFile),
			nats.ClientCert(s.cfg.Security.TLS.CertFile, s.cfg.Security.TLS.KeyFile),
		)
	}

	nc, err := nats.Connect(s.cfg.NATSURL, opts...)
	if err != nil {
		return err
	}

	s.nc = nc

	var js jetstream.JetStream

	if s.cfg.Domain != "" {
		js, err = jetstream.NewWithDomain(nc, s.cfg.Domain)
	} else {
		js, err = jetstream.New(nc)
	}

	if err != nil {
		nc.Close()
		return err
	}

	s.js = js

	stream, err := js.Stream(ctx, s.cfg.StreamName)
	if errors.Is(err, jetstream.ErrStreamNotFound) {
		sc := jetstream.StreamConfig{Name: s.cfg.StreamName}

		if s.cfg.Subject != "" {
			sc.Subjects = []string{s.cfg.Subject}
		}

		stream, err = js.CreateOrUpdateStream(ctx, sc)
		if err != nil {
			nc.Close()
			return fmt.Errorf("failed to create stream %s: %w", s.cfg.StreamName, err)
		}
	} else if err != nil {
		nc.Close()

		return fmt.Errorf("failed to get stream %s: %w", s.cfg.StreamName, err)
	}

	if _, err = stream.Info(ctx); err != nil {
		nc.Close()

		return fmt.Errorf("failed to get stream info: %w", err)
	}

	// Collect all subjects from streams configuration
	var subjects []string

	streams := s.cfg.GetStreams()

	if len(streams) > 0 {
		for _, stream := range streams {
			subjects = append(subjects, stream.Subject)
		}
	} else if s.cfg.Subject != "" {
		subjects = []string{s.cfg.Subject}
	}

	s.consumer, err = NewConsumer(ctx, js, s.cfg.StreamName, s.cfg.ConsumerName, subjects, s.logger)
	if err != nil {
		nc.Close()
		return err
	}

	s.wg.Add(1)

	go func() {
		defer s.wg.Done()
		s.consumer.ProcessMessages(ctx, s.processor)
	}()

	s.logger.Info().
		Str("stream_name", s.cfg.StreamName).
		Str("consumer_name", s.cfg.ConsumerName).
		Msg("DB event writer started")

	return nil
}

const shutdownTimeout = 10 * time.Second

// Stop shuts down the service.
func (s *Service) Stop(ctx context.Context) error {
	_, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	if s.db != nil {
		_ = s.db.Close()
	}

	if s.nc != nil {
		s.nc.Close()
	}

	s.wg.Wait()

	s.logger.Info().Msg("DB event writer stopped")

	return nil
}

var _ lifecycle.Service = (*Service)(nil)
