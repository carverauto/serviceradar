package dbeventwriter

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/natsutil"
)

// Service implements lifecycle.Service for the DB event writer.
type Service struct {
	cfg            *DBEventWriterConfig
	nc             *nats.Conn
	js             jetstream.JetStream
	consumer       *Consumer
	processor      *Processor
	wg             sync.WaitGroup
	db             db.Service
	logger         logger.Logger
	runCancel      context.CancelFunc
	connectFactory func(context.Context) (*nats.Conn, jetstream.JetStream, *Consumer, error)
	mu             sync.Mutex
	retryDelay     time.Duration
}

var (
	ErrNilConfig    = errors.New("db-event-writer: config is nil")
	ErrNilDBService = errors.New("db-event-writer: db service is nil")
)

func buildProcessor(cfg *DBEventWriterConfig, dbService db.Service, log logger.Logger) (*Processor, error) {
	if cfg == nil {
		return nil, ErrNilConfig
	}
	if dbService == nil {
		return nil, ErrNilDBService
	}

	streams := cfg.GetStreams()
	if len(streams) > 0 {
		return NewProcessorWithStreams(dbService, streams, log)
	}

	return NewProcessor(dbService, cfg.Table, log)
}

// NewService initializes the service.
func NewService(cfg *DBEventWriterConfig, dbService db.Service, log logger.Logger) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	proc, err := buildProcessor(cfg, dbService, log)
	if err != nil {
		return nil, err
	}

	svc := &Service{cfg: cfg, processor: proc, db: dbService, logger: log}
	svc.connectFactory = svc.createConnection
	svc.retryDelay = connectionRetryDelay

	return svc, nil
}

// Start connects to NATS and begins processing messages.
func (s *Service) Start(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	s.runCancel = cancel

	s.wg.Add(1)
	go s.run(runCtx)

	s.logger.Info().
		Str("stream_name", s.cfg.StreamName).
		Str("consumer_name", s.cfg.ConsumerName).
		Msg("DB event writer started")

	return nil
}

const (
	shutdownTimeout      = 10 * time.Second
	connectionRetryDelay = 5 * time.Second
)

// Stop shuts down the service.
func (s *Service) Stop(ctx context.Context) error {
	if s.runCancel != nil {
		s.runCancel()
	}

	waitCtx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	done := make(chan struct{})
	go func() {
		s.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-waitCtx.Done():
		s.logger.Warn().Msg("Timed out waiting for message loop to stop")
	}

	s.wg.Wait()

	if s.db != nil {
		_ = s.db.Close()
	}

	s.resetConnection()

	s.logger.Info().Msg("DB event writer stopped")

	return nil
}

// UpdateConfig restarts internal consumer and NATS connection using the new configuration.
func (s *Service) UpdateConfig(ctx context.Context, cfg *DBEventWriterConfig) error {
	if cfg == nil {
		return nil
	}

	if err := cfg.Validate(); err != nil {
		return err
	}

	if s.runCancel != nil {
		s.runCancel()
	}

	s.wg.Wait()
	s.resetConnection()

	proc, err := buildProcessor(cfg, s.db, s.logger)
	if err != nil {
		return err
	}

	s.cfg = cfg
	s.processor = proc

	return s.Start(ctx)
}

// ReloadDatabase rebuilds the CNPG connection and restarts the NATS consumer loop.
// It is safe to call while the service is running.
func (s *Service) ReloadDatabase(ctx context.Context, dbService db.Service) error {
	if dbService == nil {
		return nil
	}

	if s.runCancel != nil {
		s.runCancel()
	}

	s.wg.Wait()
	s.resetConnection()

	proc, err := buildProcessor(s.cfg, dbService, s.logger)
	if err != nil {
		return err
	}

	oldDB := s.db
	s.db = dbService
	s.processor = proc
	if oldDB != nil {
		_ = oldDB.Close()
	}

	return s.Start(ctx)
}

var _ lifecycle.Service = (*Service)(nil)

func (s *Service) run(ctx context.Context) {
	defer s.wg.Done()

	for {
		consumer, err := s.ensureConsumer(ctx)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, context.Canceled) {
				return
			}

			s.logger.Error().Err(err).Msg("Failed to (re)establish NATS consumer; retrying")
			if !sleepWithContext(ctx, s.retryDelay) {
				return
			}

			continue
		}

		err = consumer.ProcessMessages(ctx, s.processor)
		if err == nil || ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return
		}

		s.logger.Warn().Err(err).Msg("Message processing stopped; resetting connection")
		s.resetConnection()

		if !sleepWithContext(ctx, s.retryDelay) {
			return
		}
	}
}

func (s *Service) ensureConsumer(ctx context.Context) (*Consumer, error) {
	for {
		s.mu.Lock()
		existing := s.consumer
		s.mu.Unlock()

		if existing != nil {
			return existing, nil
		}

		consumer, err := s.establishConnection(ctx)
		if err == nil {
			s.logger.Info().
				Str("stream_name", s.cfg.StreamName).
				Str("consumer_name", s.cfg.ConsumerName).
				Msg("Connected to NATS consumer")
			return consumer, nil
		}

		// Treat transient connection/setup errors as retryable so we don't exit the process.
		if ctx.Err() != nil {
			return nil, err
		}

		s.logger.Warn().Err(err).Msg("Failed to (re)establish NATS consumer; retrying")
		if !sleepWithContext(ctx, s.retryDelay) {
			return nil, ctx.Err()
		}
	}
}

func (s *Service) establishConnection(ctx context.Context) (*Consumer, error) {
	nc, js, consumer, err := s.connectFactory(ctx)
	if err != nil {
		return nil, err
	}

	s.setConnection(nc, js, consumer)

	return consumer, nil
}

func (s *Service) setConnection(nc *nats.Conn, js jetstream.JetStream, consumer *Consumer) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.nc != nil {
		s.nc.Close()
	}

	s.nc = nc
	s.js = js
	s.consumer = consumer
}

func (s *Service) resetConnection() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.nc != nil {
		s.nc.Close()
	}

	s.nc = nil
	s.js = nil
	s.consumer = nil
}

func (s *Service) createConnection(ctx context.Context) (*nats.Conn, jetstream.JetStream, *Consumer, error) {
	subjects := s.subjects()

	opts := []nats.Option{
		nats.MaxReconnects(-1),
		nats.RetryOnFailedConnect(true),
		nats.ReconnectWait(2 * time.Second),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			if err != nil {
				s.logger.Warn().Err(err).Msg("Disconnected from NATS")
			} else {
				s.logger.Warn().Msg("Disconnected from NATS")
			}
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			s.logger.Info().
				Str("url", nc.ConnectedUrl()).
				Msg("Reconnected to NATS")
		}),
		nats.ClosedHandler(func(nc *nats.Conn) {
			s.logger.Warn().
				Str("status", nc.Status().String()).
				Msg("NATS connection closed")
		}),
	}

	if s.cfg.NATSSecurity != nil {
		tlsConf, err := natsutil.TLSConfig(s.cfg.NATSSecurity)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("failed to build NATS TLS config: %w", err)
		}

		opts = append(opts,
			nats.Secure(tlsConf),
			nats.RootCAs(s.cfg.NATSSecurity.TLS.CAFile),
			nats.ClientCert(s.cfg.NATSSecurity.TLS.CertFile, s.cfg.NATSSecurity.TLS.KeyFile),
		)
	}

	if strings.TrimSpace(s.cfg.NATSCredsFile) != "" {
		opts = append(opts, nats.UserCredentials(strings.TrimSpace(s.cfg.NATSCredsFile)))
	}

	nc, err := nats.Connect(s.cfg.NATSURL, opts...)
	if err != nil {
		return nil, nil, nil, err
	}

	var js jetstream.JetStream

	if s.cfg.Domain != "" {
		js, err = jetstream.NewWithDomain(nc, s.cfg.Domain)
	} else {
		js, err = jetstream.New(nc)
	}

	if err != nil {
		nc.Close()
		return nil, nil, nil, err
	}

	stream, err := js.Stream(ctx, s.cfg.StreamName)
	if errors.Is(err, jetstream.ErrStreamNotFound) {
		sc := jetstream.StreamConfig{Name: s.cfg.StreamName}
		if len(subjects) > 0 {
			sc.Subjects = subjects
		}

		stream, err = js.CreateOrUpdateStream(ctx, sc)
		if err != nil {
			nc.Close()
			return nil, nil, nil, fmt.Errorf("failed to create stream %s: %w", s.cfg.StreamName, err)
		}
	} else if err != nil {
		nc.Close()
		return nil, nil, nil, fmt.Errorf("failed to get stream %s: %w", s.cfg.StreamName, err)
	}

	if _, err = stream.Info(ctx); err != nil {
		nc.Close()
		return nil, nil, nil, fmt.Errorf("failed to get stream info: %w", err)
	}

	consumer, err := NewConsumer(ctx, js, s.cfg.StreamName, s.cfg.ConsumerName, subjects, s.logger)
	if err != nil {
		nc.Close()
		return nil, nil, nil, err
	}

	return nc, js, consumer, nil
}

func (s *Service) subjects() []string {
	streams := s.cfg.GetStreams()
	if len(streams) > 0 {
		subjects := make([]string, 0, len(streams))
		for _, stream := range streams {
			if stream.Subject != "" {
				subjects = append(subjects, stream.Subject)
			}
		}

		return subjects
	}

	if s.cfg.Subject != "" {
		return []string{s.cfg.Subject}
	}

	return nil
}

func sleepWithContext(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		select {
		case <-ctx.Done():
			return false
		default:
			return true
		}
	}

	timer := time.NewTimer(d)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
