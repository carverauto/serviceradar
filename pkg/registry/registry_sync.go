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

package registry

import (
	"context"
	"fmt"
	"sync"
	"time"
)

const (
	// DefaultSyncInterval is the default interval for periodic registry sync.
	DefaultSyncInterval = 5 * time.Minute
	// syncBatchSize is the batch size for syncing devices from CNPG.
	syncBatchSize = 512
)

// SyncConfig holds configuration for the registry sync process.
type SyncConfig struct {
	// Interval is how often to sync from CNPG (default: 5m).
	Interval time.Duration
	// OnStartup if true, triggers a sync immediately on Start().
	OnStartup bool
}

// registrySyncer manages periodic synchronization between in-memory registry and CNPG.
type registrySyncer struct {
	registry *DeviceRegistry
	config   SyncConfig
	stopCh   chan struct{}
	wg       sync.WaitGroup
	mu       sync.Mutex
	running  bool
}

// newRegistrySyncer creates a new syncer for the given registry.
func newRegistrySyncer(registry *DeviceRegistry, config SyncConfig) *registrySyncer {
	if config.Interval <= 0 {
		config.Interval = DefaultSyncInterval
	}
	return &registrySyncer{
		registry: registry,
		config:   config,
		stopCh:   make(chan struct{}),
	}
}

// SyncRegistryFromCNPG synchronizes the in-memory device registry with the CNPG database.
// This method can be called on-demand to refresh the registry state.
// It returns the number of devices synced and any error encountered.
func (r *DeviceRegistry) SyncRegistryFromCNPG(ctx context.Context) (int, error) {
	if r.db == nil {
		return 0, errRegistryDatabaseUnavailable
	}

	start := time.Now()

	// Use HydrateFromStore which already implements the sync logic
	count, err := r.HydrateFromStore(ctx)
	if err != nil {
		recordRegistrySyncMetrics(0, 0, time.Since(start), false)
		return 0, fmt.Errorf("sync registry from CNPG: %w", err)
	}

	// Get CNPG count for drift detection
	cnpgCount, cnpgErr := r.db.CountUnifiedDevices(ctx)
	if cnpgErr != nil {
		if r.logger != nil {
			r.logger.Warn().Err(cnpgErr).Msg("Failed to count CNPG devices during registry sync")
		}
	}

	// Record metrics
	recordRegistrySyncMetrics(int64(count), cnpgCount, time.Since(start), true)

	if r.logger != nil {
		r.logger.Info().
			Int("registry_count", count).
			Int64("cnpg_count", cnpgCount).
			Dur("duration", time.Since(start)).
			Msg("Registry synced from CNPG")
	}

	return count, nil
}

// DeviceCount returns the current count of devices in the in-memory registry.
func (r *DeviceRegistry) DeviceCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.devices)
}

// StartPeriodicSync starts a background goroutine that periodically syncs the registry.
// It returns a stop function that should be called to stop the periodic sync.
func (r *DeviceRegistry) StartPeriodicSync(ctx context.Context, config SyncConfig) func() {
	syncer := newRegistrySyncer(r, config)
	syncer.start(ctx)
	return syncer.stop
}

// start begins the periodic sync process.
func (s *registrySyncer) start(ctx context.Context) {
	s.mu.Lock()
	if s.running {
		s.mu.Unlock()
		return
	}
	s.running = true
	s.stopCh = make(chan struct{})
	s.mu.Unlock()

	s.wg.Add(1)
	go s.run(ctx)
}

// stop halts the periodic sync process.
func (s *registrySyncer) stop() {
	s.mu.Lock()
	if !s.running {
		s.mu.Unlock()
		return
	}
	s.running = false
	close(s.stopCh)
	s.mu.Unlock()
	s.wg.Wait()
}

// run is the main sync loop.
func (s *registrySyncer) run(ctx context.Context) {
	defer s.wg.Done()

	// Sync immediately on startup if configured
	if s.config.OnStartup {
		if _, err := s.registry.SyncRegistryFromCNPG(ctx); err != nil {
			if s.registry.logger != nil {
				s.registry.logger.Warn().Err(err).Msg("Initial registry sync failed")
			}
		}
	}

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.stopCh:
			return
		case <-ticker.C:
			syncCtx, cancel := context.WithTimeout(ctx, s.config.Interval/2)
			if _, err := s.registry.SyncRegistryFromCNPG(syncCtx); err != nil {
				if s.registry.logger != nil {
					s.registry.logger.Warn().Err(err).Msg("Periodic registry sync failed")
				}
			}
			cancel()
		}
	}
}

// WithSyncInterval sets the sync interval for the registry.
func WithSyncInterval(interval time.Duration) Option {
	return func(r *DeviceRegistry) {
		if interval > 0 {
			r.syncInterval = interval
		}
	}
}
