/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package mdns

import (
	"context"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// MdnsService orchestrates the mDNS listener, publisher, and dedup cleanup goroutines.
type MdnsService struct {
	config    *Config
	listener  *Listener
	publisher *Publisher
	dedup     *DedupCache
	ch        chan []byte
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	logger    logger.Logger
	started   bool
	mu        sync.Mutex
}

// NewMdnsService creates a new mDNS service from the given config.
func NewMdnsService(config *Config, log logger.Logger) (*MdnsService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	ch := make(chan []byte, config.ChannelSize)
	dedup := NewDedupCache(config.DedupTTLSecs, config.DedupMaxEntries)

	return &MdnsService{
		config:    config,
		dedup:     dedup,
		ch:        ch,
		listener:  NewListener(config, dedup, ch, log),
		publisher: NewPublisher(config, ch, log),
		logger:    log,
	}, nil
}

// Start initializes the NATS connection, binds the multicast socket,
// and starts the listener, publisher, and dedup cleanup goroutines.
func (s *MdnsService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return nil
	}

	// Connect publisher to NATS
	if err := s.publisher.Connect(ctx); err != nil {
		return err
	}

	// Start multicast listener
	if err := s.listener.Start(); err != nil {
		s.publisher.Close()
		return err
	}

	ctx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	// Start listener goroutine
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.listener.Run()
	}()

	// Start publisher goroutine
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.publisher.Run(ctx)
	}()

	// Start dedup cleanup goroutine
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.runDedupCleanup(ctx)
	}()

	s.started = true
	s.logger.Info().Msg("mDNS service started")
	return nil
}

// Stop gracefully shuts down the service.
func (s *MdnsService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.started {
		return nil
	}

	s.started = false

	// Close listener (stops Run loop)
	if err := s.listener.Close(); err != nil {
		s.logger.Warn().Err(err).Msg("Error closing mDNS listener")
	}

	// Cancel context (stops publisher and cleanup)
	if s.cancel != nil {
		s.cancel()
	}

	// Close channel to signal publisher
	close(s.ch)

	// Wait for goroutines to finish
	s.wg.Wait()

	// Close NATS connection
	s.publisher.Close()

	s.logger.Info().Msg("mDNS service stopped")
	return nil
}

func (s *MdnsService) runDedupCleanup(ctx context.Context) {
	interval := time.Duration(s.config.DedupCleanupIntervalSecs) * time.Second
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			removed := s.dedup.Cleanup()
			if removed > 0 {
				s.logger.Debug().Int("removed", removed).Int("remaining", s.dedup.Len()).Msg("Dedup cleanup completed")
			}
		}
	}
}
