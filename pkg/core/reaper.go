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

package core

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/registry"
)

// StaleDeviceReaper is responsible for cleaning up stale, IP-only devices.
// These are devices that were discovered via sweep (IP-only) but never acquired
// strong identifiers (MAC, Armis ID, etc.) and have not been seen for a while.
// This helps prevent unlimited growth of orphaned devices due to DHCP churn.
type StaleDeviceReaper struct {
	db       db.Service
	registry registry.Manager
	logger   logger.Logger
	interval time.Duration
	ttl      time.Duration
}

// NewStaleDeviceReaper creates a new StaleDeviceReaper.
func NewStaleDeviceReaper(database db.Service, reg registry.Manager, log logger.Logger, interval, ttl time.Duration) *StaleDeviceReaper {
	return &StaleDeviceReaper{
		db:       database,
		registry: reg,
		logger:   log,
		interval: interval,
		ttl:      ttl,
	}
}

// Start starts the reaper background loop.
func (r *StaleDeviceReaper) Start(ctx context.Context) {
	r.logger.Info().
		Str("interval", r.interval.String()).
		Str("ttl", r.ttl.String()).
		Msg("Starting stale device reaper")

	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			r.logger.Info().Msg("Stale device reaper stopping")
			return
		case <-ticker.C:
			if err := r.reap(ctx); err != nil {
				r.logger.Error().Err(err).Msg("Failed to reap stale devices")
			}
		}
	}
}

// reap executes a single cleanup cycle.
func (r *StaleDeviceReaper) reap(ctx context.Context) error {
	// 1. Identify stale IP-only devices
	staleIDs, err := r.db.GetStaleIPOnlyDevices(ctx, r.ttl)
	if err != nil {
		return err
	}

	if len(staleIDs) == 0 {
		return nil
	}

	r.logger.Info().
		Int("count", len(staleIDs)).
		Msg("Found stale IP-only devices to reap")

	// 2. Soft-delete them from DB
	if err := r.db.SoftDeleteDevices(ctx, staleIDs); err != nil {
		return err
	}

	// 3. Remove them from in-memory registry
	if r.registry != nil {
		for _, id := range staleIDs {
			r.registry.DeleteLocal(id)
		}
	}

	r.logger.Info().
		Int("count", len(staleIDs)).
		Msg("Successfully reaped stale IP-only devices")

	return nil
}
