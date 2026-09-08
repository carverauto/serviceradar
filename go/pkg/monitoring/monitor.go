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

// Package monitoring pkg/monitoring/monitor.go
package monitoring

import (
	"context"
	"log"
	"time"
)

// MonitorConfig holds configuration for monitoring.
type MonitorConfig struct {
	Interval       time.Duration
	AlertThreshold time.Duration
}

// Monitor represents a generic monitoring system.
type Monitor struct {
	config MonitorConfig
	done   chan struct{}
}

// NewMonitor creates a new monitoring system.
func NewMonitor(cfg MonitorConfig) *Monitor {
	return &Monitor{
		config: cfg,
		done:   make(chan struct{}),
	}
}

// StartMonitoring starts monitoring in a background goroutine.
func (m *Monitor) StartMonitoring(ctx context.Context, check func(context.Context) error) {
	ticker := time.NewTicker(m.config.Interval)
	defer ticker.Stop()

	// Do initial check
	if err := check(ctx); err != nil {
		log.Printf("Initial check failed: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-m.done:
			return
		case <-ticker.C:
			if err := check(ctx); err != nil {
				log.Printf("Check failed: %v", err)
			}
		}
	}
}

// Stop stops the monitoring.
func (m *Monitor) Stop(_ context.Context) {
	close(m.done)
}
