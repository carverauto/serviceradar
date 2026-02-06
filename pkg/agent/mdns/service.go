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

// MdnsRecordJSON is a JSON-serializable mDNS record for the gRPC push pipeline.
type MdnsRecordJSON struct {
	RecordType     string `json:"record_type"`
	TimeReceivedNs uint64 `json:"time_received_ns"`
	SourceIP       string `json:"source_ip"`
	Hostname       string `json:"hostname"`
	ResolvedAddr   string `json:"resolved_addr"`
	DnsTTL         uint32 `json:"dns_ttl"`
	DnsName        string `json:"dns_name"`
	IsResponse     bool   `json:"is_response"`
}

// MdnsService orchestrates the mDNS listener and dedup cleanup goroutines.
// Records are buffered and drained by the push loop via DrainRecords().
type MdnsService struct {
	config   *Config
	listener *Listener
	dedup    *DedupCache
	ch       chan *MdnsRecordJSON
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	logger   logger.Logger
	started  bool
	mu       sync.Mutex

	// Drain buffer: accumulated records waiting for push loop to collect
	records   []MdnsRecordJSON
	recordsMu sync.Mutex
}

// NewMdnsService creates a new mDNS service from the given config.
func NewMdnsService(config *Config, log logger.Logger) (*MdnsService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	ch := make(chan *MdnsRecordJSON, config.ChannelSize)
	dedup := NewDedupCache(config.DedupTTLSecs, config.DedupMaxEntries)

	maxBuf := config.MaxBufferedRecords
	if maxBuf <= 0 {
		maxBuf = 1000
	}

	return &MdnsService{
		config:   config,
		dedup:    dedup,
		ch:       ch,
		listener: NewListener(config, dedup, ch, log),
		records:  make([]MdnsRecordJSON, 0, maxBuf),
		logger:   log,
	}, nil
}

// Start binds the multicast socket and starts the listener, buffer,
// and dedup cleanup goroutines.
func (s *MdnsService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return nil
	}

	// Start multicast listener
	if err := s.listener.Start(); err != nil {
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

	// Start buffer goroutine (reads from channel, appends to drain buffer)
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.runBuffer(ctx)
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

	// Cancel context (stops buffer and cleanup goroutines)
	if s.cancel != nil {
		s.cancel()
	}

	// Close channel to signal buffer goroutine
	close(s.ch)

	// Wait for goroutines to finish
	s.wg.Wait()

	s.logger.Info().Msg("mDNS service stopped")
	return nil
}

// DrainRecords returns and clears the buffered records.
// Called by the push loop to collect records for gRPC streaming.
func (s *MdnsService) DrainRecords() []MdnsRecordJSON {
	s.recordsMu.Lock()
	defer s.recordsMu.Unlock()

	if len(s.records) == 0 {
		return nil
	}

	drained := s.records
	maxBuf := s.config.MaxBufferedRecords
	if maxBuf <= 0 {
		maxBuf = 1000
	}
	s.records = make([]MdnsRecordJSON, 0, maxBuf)
	return drained
}

// runBuffer reads records from the channel and appends them to the drain buffer.
func (s *MdnsService) runBuffer(ctx context.Context) {
	maxBuf := s.config.MaxBufferedRecords
	if maxBuf <= 0 {
		maxBuf = 1000
	}

	for {
		select {
		case <-ctx.Done():
			return
		case record, ok := <-s.ch:
			if !ok {
				return
			}

			s.recordsMu.Lock()
			if len(s.records) < maxBuf {
				s.records = append(s.records, *record)
			} else {
				s.logger.Warn().Msg("mDNS drain buffer full, dropping record")
			}
			s.recordsMu.Unlock()
		}
	}
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
