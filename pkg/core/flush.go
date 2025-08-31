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

	const numBufferTypes = 4 // metrics, service statuses, availability metrics, and trace data
	wg.Add(numBufferTypes)

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

		s.flushServiceStatusBatch(ctx, pollerID, statuses)
		s.serviceBuffers[pollerID] = nil
	}
}

// flushServiceStatusBatch processes a single poller's service status batch
func (s *Server) flushServiceStatusBatch(ctx context.Context, pollerID string, statuses []*models.ServiceStatus) {
	// With sync services now chunked at the streaming level, we should not have oversized records
	const maxBatchSizeBytes = 5 * 1024 * 1024 // 5MB batch limit

	totalSize := s.calculateBatchSize(statuses)

	s.logger.Debug().
		Str("poller_id", pollerID).
		Int("status_count", len(statuses)).
		Int("estimated_size_bytes", totalSize).
		Msg("FLUSH DEBUG: Starting service status batch processing")

	// Separate sync services from others for special handling
	syncServices := make([]*models.ServiceStatus, 0)
	nonSyncServices := make([]*models.ServiceStatus, 0)

	for _, status := range statuses {
		s.logger.Debug().
			Str("service_name", status.ServiceName).
			Str("service_type", status.ServiceType).
			Int("message_size", len(status.Message)).
			Int("details_size", len(status.Details)).
			Msg("FLUSH DEBUG: Processing service in batch")

		if status.ServiceType == syncServiceType {
			syncServices = append(syncServices, status)
		} else {
			nonSyncServices = append(nonSyncServices, status)
		}
	}

	// Handle sync services individually to avoid batch size issues
	for _, status := range syncServices {
		detailsSize := len(status.Details)
		s.logger.Debug().
			Str("service_name", status.ServiceName).
			Int("details_size", detailsSize).
			Msg("FLUSH DEBUG: Flushing large sync service individually")

		if err := s.DB.UpdateServiceStatuses(ctx, []*models.ServiceStatus{status}); err != nil {
			s.logger.Error().
				Err(err).
				Str("service_name", status.ServiceName).
				Str("poller_id", pollerID).
				Int("details_size", detailsSize).
				Msg("Failed to flush sync service")
		}
	}

	// Handle non-sync services with normal batching
	if len(nonSyncServices) == 0 {
		s.logger.Debug().
			Str("poller_id", pollerID).
			Int("sync_services_flushed", len(syncServices)).
			Msg("FLUSH DEBUG: Only sync services in batch - all handled individually")

		return // Only had sync services, we're done
	}

	// Recalculate batch info for non-sync services only
	nonSyncTotalSize := s.calculateBatchSize(nonSyncServices)

	s.logger.Debug().
		Str("poller_id", pollerID).
		Int("sync_services_flushed", len(syncServices)).
		Int("non_sync_services", len(nonSyncServices)).
		Int("non_sync_batch_size", nonSyncTotalSize).
		Msg("FLUSH DEBUG: Processing non-sync services batch")

	// Simple batch processing for non-sync services
	if nonSyncTotalSize <= maxBatchSizeBytes {
		s.flushSingleBatch(ctx, pollerID, nonSyncServices, nonSyncTotalSize)
	} else {
		// Split into smaller batches
		s.flushInSimpleBatches(ctx, pollerID, nonSyncServices, maxBatchSizeBytes)
	}
}

// calculateBatchSize estimates the total size of a service status batch
func (*Server) calculateBatchSize(statuses []*models.ServiceStatus) int {
	totalSize := 0

	for _, status := range statuses {
		// Estimate size: details + message + other fields (~200 bytes overhead per record)
		statusSize := len(status.Details) + len(status.Message) + 200
		totalSize += statusSize
	}

	return totalSize
}

// flushSingleBatch flushes a batch that fits within size limits
func (s *Server) flushSingleBatch(ctx context.Context, pollerID string, statuses []*models.ServiceStatus, totalSize int) {
	if err := s.DB.UpdateServiceStatuses(ctx, statuses); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", pollerID).
			Int("status_count", len(statuses)).
			Int("estimated_size_bytes", totalSize).
			Msg("Failed to flush service statuses")
	} else {
		s.logger.Debug().
			Str("poller_id", pollerID).
			Int("status_count", len(statuses)).
			Int("estimated_size_bytes", totalSize).
			Msg("Successfully flushed service status batch")
	}
}

// flushInSimpleBatches splits and flushes a large batch into smaller batches
func (s *Server) flushInSimpleBatches(
	ctx context.Context, pollerID string, statuses []*models.ServiceStatus, maxBatchSizeBytes int) {
	s.logger.Info().
		Str("poller_id", pollerID).
		Int("total_statuses", len(statuses)).
		Msg("Splitting large batch into smaller batches")

	// Pre-allocate batch with estimated capacity
	// Assuming average service status size ~1KB, estimate batch capacity
	estimatedCapacity := maxBatchSizeBytes / 1024

	if estimatedCapacity < 10 {
		estimatedCapacity = 10
	}

	batch := make([]*models.ServiceStatus, 0, estimatedCapacity)

	batchSize := 0

	for _, status := range statuses {
		statusSize := len(status.Details) + len(status.Message) + 200 // Estimate overhead

		// If adding this status would exceed the limit, flush current batch
		if len(batch) > 0 && (batchSize+statusSize > maxBatchSizeBytes) {
			s.flushSingleBatch(ctx, pollerID, batch, batchSize)

			batch = []*models.ServiceStatus{}
			batchSize = 0
		}

		batch = append(batch, status)
		batchSize += statusSize
	}

	// Flush remaining batch
	if len(batch) > 0 {
		s.flushSingleBatch(ctx, pollerID, batch, batchSize)
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

		s.logger.Debug().
			Str("poller_id", pollerID).
			Int("service_count", len(services)).
			Msg("Flushing services to database")

		for i, service := range services {
			s.logger.Debug().
				Str("poller_id", pollerID).
				Int("service_index", i).
				Str("service_name", service.ServiceName).
				Str("service_type", service.ServiceType).
				Interface("config", service.Config).
				Msg("Service being stored")
		}

		if err := s.DB.StoreServices(ctx, services); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Int("service_count", len(services)).
				Msg("Failed to flush services")
		} else {
			s.logger.Info().
				Str("poller_id", pollerID).
				Int("service_count", len(services)).
				Msg("Successfully flushed services to database")
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
