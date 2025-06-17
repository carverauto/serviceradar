package devices

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

type Service struct {
	cfg       *DeviceConsumerConfig
	nc        *nats.Conn
	js        jetstream.JetStream
	consumer  *Consumer
	processor *Processor
	wg        sync.WaitGroup
	db        db.Service
}

func NewService(cfg *DeviceConsumerConfig, dbService db.Service) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	svc := &Service{cfg: cfg, processor: NewProcessor(dbService), db: dbService}
	return svc, nil
}

func (s *Service) Start(ctx context.Context) error {
	var opts []nats.Option
	if s.cfg.Security != nil {
		opts = append(opts,
			nats.ClientCert(s.cfg.Security.TLS.CertFile, s.cfg.Security.TLS.KeyFile),
			nats.RootCAs(s.cfg.Security.TLS.CAFile),
		)
	}
	nc, err := nats.Connect(s.cfg.NATSURL, opts...)
	if err != nil {
		return err
	}
	s.nc = nc
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return err
	}
	s.js = js
	stream, err := js.Stream(ctx, s.cfg.StreamName)
	if err != nil {
		nc.Close()
		return fmt.Errorf("failed to get stream %s: %w", s.cfg.StreamName, err)
	}
	if _, err = stream.Info(ctx); err != nil {
		nc.Close()
		return fmt.Errorf("failed to get stream info: %w", err)
	}
	s.consumer, err = NewConsumer(ctx, js, s.cfg.StreamName, s.cfg.ConsumerName)
	if err != nil {
		nc.Close()
		return err
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.consumer.ProcessMessages(ctx, s.processor)
	}()
	log.Printf("Device consumer started for stream %s, consumer %s", s.cfg.StreamName, s.cfg.ConsumerName)
	return nil
}

const shutdownTimeout = 10 * time.Second

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
	log.Println("Device consumer stopped")
	return nil
}

var _ lifecycle.Service = (*Service)(nil)
