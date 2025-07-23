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
	"log"
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
func (s *Server) flushAllBuffers(ctx context.Context) {
	s.bufferMu.Lock()
	defer s.bufferMu.Unlock()

	s.flushMetrics(ctx)
	s.flushServiceStatuses(ctx)
	s.flushServices(ctx)
	s.flushSysmonMetrics(ctx)
}

// flushMetrics flushes metric buffers to the database.
func (s *Server) flushMetrics(ctx context.Context) {
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
			log.Printf("CRITICAL DB WRITE ERROR: Failed to flush/StoreMetrics for poller %s: %v. "+
				"Number of metrics attempted: %d", pollerID, err, len(metricsToFlush))
		} else {
			log.Printf("Successfully flushed %d timeseries metrics for poller %s",
				len(metricsToFlush), pollerID)
		}
	}
}

// flushServiceStatuses flushes service status buffers to the database.
func (s *Server) flushServiceStatuses(ctx context.Context) {
	for pollerID, statuses := range s.serviceBuffers {
		if len(statuses) == 0 {
			continue
		}

		if err := s.DB.UpdateServiceStatuses(ctx, statuses); err != nil {
			log.Printf("Failed to flush service statuses for poller %s: %v", pollerID, err)
		}

		s.serviceBuffers[pollerID] = nil
	}
}

// flushServices flushes service inventory data to the database.
func (s *Server) flushServices(ctx context.Context) {
	for pollerID, services := range s.serviceListBuffers {
		if len(services) == 0 {
			continue
		}

		if err := s.DB.StoreServices(ctx, services); err != nil {
			log.Printf("Failed to flush services for poller %s: %v", pollerID, err)
		}

		s.serviceListBuffers[pollerID] = nil
	}
}

// flushSysmonMetrics flushes system monitor metrics to the database.
func (s *Server) flushSysmonMetrics(ctx context.Context) {
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
				log.Printf("Failed to flush sysmon metrics for poller %s: %v", pollerID, err)
			}
		}

		s.sysmonBuffers[pollerID] = nil
	}
}
