/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package netflow

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/davecgh/go-spew/spew"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Service implements the lifecycle.Service interface for the NetFlow consumer.
type Service struct {
	cfg       NetflowConfig
	nc        *nats.Conn
	js        jetstream.JetStream
	consumer  *Consumer
	processor *Processor
	wg        sync.WaitGroup
	db        db.Service
}

// NewService creates a new NetFlow consumer service.
func NewService(cfg NetflowConfig, dbService db.Service) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	svc := &Service{
		cfg:       cfg,
		processor: NewProcessor(dbService, cfg),
		db:        dbService,
	}

	spew.Dump(cfg)

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

// initSchema creates the netflow_metrics stream for Proton.
func (s *Service) initSchema(ctx context.Context) error {
	// Build netflow_metrics stream definition dynamically
	var columns []string
	enabledKeys := make(map[models.ColumnKey]bool)
	disabledKeys := make(map[models.ColumnKey]bool)

	for _, key := range s.cfg.EnabledFields {
		enabledKeys[key] = true
	}
	for _, key := range s.cfg.DisabledFields {
		disabledKeys[key] = true
	}

	for _, def := range models.ColumnDefinitions {
		// Skip disabled columns, include enabled or mandatory columns
		if disabledKeys[def.Key] && !def.Mandatory {
			continue
		}
		if !enabledKeys[def.Key] && !def.Mandatory && def.Default == "" && def.Alias == "" {
			continue
		}

		columnDef := fmt.Sprintf("`%s` %s", def.Name, def.Type)
		if def.Codec != "" {
			columnDef += fmt.Sprintf(" CODEC(%s)", def.Codec)
		}
		if def.Default != "" {
			columnDef += fmt.Sprintf(" DEFAULT %s", def.Default)
		}
		if def.Alias != "" {
			columnDef += fmt.Sprintf(" ALIAS %s", def.Alias)
		}
		columns = append(columns, columnDef)
	}

	createStream := fmt.Sprintf(`CREATE STREAM IF NOT EXISTS netflow_metrics (
		%s
	) ENGINE = Stream(1, 1, sip_hash64(src_addr))
	PARTITION BY date(timestamp)
	ORDER BY (src_addr, dst_addr, sampler_address, timestamp)
	SETTINGS mode='append'`, strings.Join(columns, ",\n"))

	log.Printf("Generated CREATE STREAM query: %s", createStream)

	dbImpl, ok := s.db.(*db.DB)
	if !ok {
		return fmt.Errorf("db.Service is not *db.DB")
	}

	if err := dbImpl.Conn.Exec(ctx, createStream); err != nil {
		return fmt.Errorf("failed to create netflow_metrics stream: %w", err)
	}

	return nil
}

// Ensure Service implements lifecycle.Service
var _ lifecycle.Service = (*Service)(nil)
