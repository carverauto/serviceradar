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

package mapper

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
)

func (e *DiscoveryEngine) StartDiscovery(ctx context.Context, params *DiscoveryParams) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Validate params
	if len(params.Seeds) == 0 {
		return "", ErrNoSeedsProvided
	}

	// Generate a unique discovery ID
	discoveryID := generateDiscoveryID()

	// Create a job-specific cancellable context
	jobCtx, cancel := context.WithCancel(ctx)

	// Create a new discovery job
	results := &DiscoveryResults{
		Status: &DiscoveryStatus{
			Status:    DiscoveryStatusPending,
			Progress:  0,
			StartTime: time.Now(),
		},
		Devices:       make([]*DiscoveredDevice, 0),
		Interfaces:    make([]*DiscoveredInterface, 0),
		TopologyLinks: make([]*TopologyLink, 0),
		Contract: DiscoveryContract{
			AgentID:          params.AgentID,
			GatewayID:        params.GatewayID,
			TopologyContract: topologyContractV2,
			ParseDiagnostics: DiscoveryParseDiagnostics{
				ParseFailures:     make(map[string]int),
				UnknownTopLevel:   make(map[string]int),
				ParserMismatches:  make(map[string]int),
				LastFailureByType: make(map[string]string),
			},
		},
	}

	job := &DiscoveryJob{
		ID:           discoveryID,
		Params:       params,
		Results:      results,
		Status:       results.Status, // Point to the same status
		ctx:          jobCtx,
		cancelFunc:   cancel,
		deviceMap:    make(map[string]*DeviceInterfaceMap),
		interfaceMap: make(map[string]*DiscoveredInterface),
	}

	// Store the job
	e.activeJobs[discoveryID] = job

	// Enqueue the job
	select {
	case e.jobChan <- job:
		e.logger.Info().Str("discovery_id", discoveryID).Msg("Discovery job enqueued")
	default:
		cancel() // Clean up context
		delete(e.activeJobs, discoveryID)

		return "", ErrJobQueueFull
	}

	return discoveryID, nil
}

// generateDiscoveryID creates a unique ID for a discovery job
func generateDiscoveryID() string {
	return uuid.New().String()
}

// GetDiscoveryStatus retrieves the status of a discovery operation
func (e *DiscoveryEngine) GetDiscoveryStatus(_ context.Context, discoveryID string) (*DiscoveryStatus, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if job, ok := e.activeJobs[discoveryID]; ok {
		// Return a copy to prevent modification
		statusCopy := *job.Status

		return &statusCopy, nil
	}

	if results, ok := e.completedJobs[discoveryID]; ok {
		// Return a copy
		statusCopy := *results.Status

		return &statusCopy, nil
	}

	return nil, fmt.Errorf("%w: %s", ErrDiscoveryJobNotFound, discoveryID)
}

// GetDiscoveryResults retrieves the results of a completed discovery operation
func (e *DiscoveryEngine) GetDiscoveryResults(
	_ context.Context, discoveryID string, includeRawData bool) (*DiscoveryResults, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if results, ok := e.completedJobs[discoveryID]; ok {
		// Return a copy. If includeRawData is false, redact contract metadata
		// that is only intended for debug/trace responses.
		resultsCopy := *results
		if !includeRawData {
			resultsCopy.Contract = DiscoveryContract{
				AgentID:          results.Contract.AgentID,
				GatewayID:        results.Contract.GatewayID,
				TopologyContract: results.Contract.TopologyContract,
			}
		}

		return &resultsCopy, nil
	}

	if job, ok := e.activeJobs[discoveryID]; ok {
		return nil, fmt.Errorf("%w: %s, status: %s", ErrDiscoveryJobStillActive, discoveryID, job.Status.Status)
	}

	return nil, fmt.Errorf("%w: %s", ErrDiscoveryJobNotCompleted, discoveryID)
}

// CancelDiscovery cancels an in-progress discovery operation
func (e *DiscoveryEngine) CancelDiscovery(_ context.Context, discoveryID string) error {
	e.mu.Lock()
	job, ok := e.activeJobs[discoveryID]

	if !ok {
		e.mu.Unlock()
		// Check if already completed and canceled
		if compJob, compOk := e.completedJobs[discoveryID]; compOk {
			if compJob.Status.Status == DiscoverStatusCanceled {
				return nil // Already canceled
			}
		}

		return fmt.Errorf("%w: %s", ErrDiscoveryJobNotActive, discoveryID)
	}

	// Job is active, proceed to cancel under lock
	job.cancelFunc() // Signal the job's context to cancel

	job.Status.Status = DiscoverStatusCanceled
	job.Status.EndTime = time.Now()
	job.Status.Error = "Job canceled by user"
	job.Status.Progress = 100 // Or current progress if preferred

	// Move to completed jobs
	e.completedJobs[discoveryID] = job.Results       // Store the partial/final results
	e.completedJobs[discoveryID].Status = job.Status // Ensure status in completedJobs is also updated

	delete(e.activeJobs, discoveryID)
	e.mu.Unlock()

	e.logger.Info().Str("discovery_id", discoveryID).Msg("Discovery job canceled")

	return nil
}

// worker processes discovery jobs from jobChan
func (e *DiscoveryEngine) worker(ctx context.Context, workerID int) {
	defer e.wg.Done()

	e.logger.Info().Int("worker_id", workerID).Msg("Discovery worker started")

	for {
		select {
		case <-ctx.Done(): // Main context canceled
			e.logger.Info().Int("worker_id", workerID).
				Msg("Discovery worker stopping due to main context cancellation")

			return
		case <-e.done: // Engine stopping
			e.logger.Info().Int("worker_id", workerID).
				Msg("Discovery worker stopping due to engine shutdown")

			return
		case job, ok := <-e.jobChan:
			if !ok { // jobChan was closed
				e.logger.Info().Int("worker_id", workerID).
					Msg("Discovery worker stopping as job channel was closed")

				return
			}

			// Use the job-specific context provided when it was created
			jobSpecificCtx := job.cancelFunc // This is actually the context.Context for the job
			_ = jobSpecificCtx               // Avoid unused variable if not directly used here

			e.logger.Info().Int("worker_id", workerID).Str("job_id", job.ID).
				Msg("Worker picked up job")

			job.Status.Status = DiscoveryStatusRunning
			job.Status.Progress = 5 // Indicate it's started

			// Placeholder for actual discovery logic
			e.runDiscoveryJob(ctx, job) // Pass job.ctx here
			e.maybeExportDebugBundle(job)

			// After job execution (success, failure, or cancellation handled within runDiscoveryJob)
			e.mu.Lock()

			if _, isActive := e.activeJobs[job.ID]; isActive { // Check if not already canceled and moved
				// If not set by runDiscoveryJob (e.g. on non-error completion)
				if job.Status.Status == DiscoveryStatusRunning {
					job.Status.Status = DiscoveryStatusCompleted
					job.Status.Progress = 100
				}

				job.Status.EndTime = time.Now()

				e.completedJobs[job.ID] = job.Results
				e.completedJobs[job.ID].Status = job.Status // Ensure status is consistent

				delete(e.activeJobs, job.ID)
			}

			e.mu.Unlock()
			e.logger.Info().Int("worker_id", workerID).Str("job_id", job.ID).
				Str("status", string(job.Status.Status)).Msg("Worker finished job")
		}
	}
}
