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
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// flushBuffers flushes buffered data to the database periodically.
func (s *Server) flushBuffers(ctx context.Context) {
	ticker := time.NewTicker(defaultFlushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.flushAllBuffers(ctx)
		}
	}
}

// flushAllBuffers flushes all buffer types to the database.
// Uses separate goroutines with individual mutexes for each buffer type
// to reduce contention and improve throughput.
func (s *Server) flushAllBuffers(ctx context.Context) {
	var wg sync.WaitGroup

	wg.Add(4)

	go func() {
		defer wg.Done()
		s.flushMetrics(ctx)
	}()

	go func() {
		defer wg.Done()
		s.flushServiceStatuses(ctx)
	}()

	go func() {
		defer wg.Done()
		s.flushServices(ctx)
	}()

	go func() {
		defer wg.Done()
		s.flushSysmonMetrics(ctx)
	}()

	wg.Wait()
}

// flushMetrics flushes metric buffers to the database.
func (s *Server) flushMetrics(ctx context.Context) {
	s.metricBufferMu.Lock()
	defer s.metricBufferMu.Unlock()

	for pollerID, timeseriesMetrics := range s.metricBuffers {
		if len(timeseriesMetrics) == 0 {
			continue
		}

		metricsToFlush := make([]*models.TimeseriesMetric, len(timeseriesMetrics))
		copy(metricsToFlush, timeseriesMetrics)
		// It's important to clear the original buffer slice for this poller ID
		// under the lock to prevent race conditions if new metrics come in
		// while StoreMetrics is running.
		s.metricBuffers[pollerID] = nil

		if err := s.DB.StoreMetrics(ctx, pollerID, metricsToFlush); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Int("metric_count", len(metricsToFlush)).
				Msg("CRITICAL DB WRITE ERROR: Failed to flush/StoreMetrics")
		} else {
			s.logger.Debug().
				Int("metric_count", len(metricsToFlush)).
				Str("poller_id", pollerID).
				Msg("Successfully flushed timeseries metrics")
		}
	}
}

// flushServiceStatuses flushes service status buffers to the database.
func (s *Server) flushServiceStatuses(ctx context.Context) {
	s.serviceBufferMu.Lock()
	defer s.serviceBufferMu.Unlock()

	for pollerID, statuses := range s.serviceBuffers {
		if len(statuses) == 0 {
			continue
		}

		if err := s.DB.UpdateServiceStatuses(ctx, statuses); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Msg("Failed to flush service statuses")
		}

		s.serviceBuffers[pollerID] = nil
	}
}

// flushServices flushes service inventory data to the database.
func (s *Server) flushServices(ctx context.Context) {
	s.serviceListBufferMu.Lock()
	defer s.serviceListBufferMu.Unlock()

	for pollerID, services := range s.serviceListBuffers {
		if len(services) == 0 {
			continue
		}

		if err := s.DB.StoreServices(ctx, services); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Msg("Failed to flush services")
		}

		s.serviceListBuffers[pollerID] = nil
	}
}

// flushSysmonMetrics flushes system monitor metrics to the database.
func (s *Server) flushSysmonMetrics(ctx context.Context) {
	s.sysmonBufferMu.Lock()
	defer s.sysmonBufferMu.Unlock()

	for pollerID, sysmonMetrics := range s.sysmonBuffers {
		if len(sysmonMetrics) == 0 {
			continue
		}

		for _, metricBuffer := range sysmonMetrics {
			metric := metricBuffer.Metrics
			partition := metricBuffer.Partition

			var ts time.Time

			var agentID, hostID, hostIP string

			// Extract information from the first available metric type
			switch {
			case len(metric.CPUs) > 0:
				ts = metric.CPUs[0].Timestamp
				agentID = metric.CPUs[0].AgentID
				hostID = metric.CPUs[0].HostID
				hostIP = metric.CPUs[0].HostIP
			case len(metric.Disks) > 0:
				ts = metric.Disks[0].Timestamp
				agentID = metric.Disks[0].AgentID
				hostID = metric.Disks[0].HostID
				hostIP = metric.Disks[0].HostIP
			default:
				ts = metric.Memory.Timestamp
				agentID = metric.Memory.AgentID
				hostID = metric.Memory.HostID
				hostIP = metric.Memory.HostIP
			}

			if err := s.DB.StoreSysmonMetrics(
				ctx, pollerID, agentID, hostID, partition, hostIP, metric, ts); err != nil {
				s.logger.Error().
					Err(err).
					Str("poller_id", pollerID).
					Msg("Failed to flush sysmon metrics")
			}
		}

		s.sysmonBuffers[pollerID] = nil
	}
}
