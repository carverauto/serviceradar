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

// Package discovery pkg/discovery/discovery.go
package discovery

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/google/uuid"
)

// NewSnmpDiscoveryEngine creates a new SNMP discovery engine with the given configuration
func NewSnmpDiscoveryEngine(config *Config, publisher Publisher) (DiscoveryEngine, error) {
	if err := validateConfig(config); err != nil {
		return nil, fmt.Errorf("invalid discovery engine configuration: %w", err)
	}

	engine := &SnmpDiscoveryEngine{
		config:        config,
		activeJobs:    make(map[string]*DiscoveryJob),
		completedJobs: make(map[string]*DiscoveryResults),
		jobChan:       make(chan *DiscoveryJob, config.MaxActiveJobs),
		workers:       config.Workers,
		publisher:     publisher,
		done:          make(chan struct{}),
		// mu is initialized by default (zero value is usable)
	}

	return engine, nil
}

// Start initializes and starts the discovery engine
func (e *SnmpDiscoveryEngine) Start(ctx context.Context) error {
	log.Printf("Starting SnmpDiscoveryEngine with %d workers and %d max active jobs...", e.workers, e.config.MaxActiveJobs)
	e.wg.Add(e.workers) // Add worker count to WaitGroup
	for i := 0; i < e.workers; i++ {
		go e.worker(ctx, i)
	}

	// Start cleanup routine for completed jobs
	e.wg.Add(1)
	go func() {
		defer e.wg.Done()
		e.cleanupRoutine(ctx) // This function is in utils.go
	}()

	log.Println("SnmpDiscoveryEngine started.")
	return nil
}

// Stop gracefully shuts down the discovery engine
func (e *SnmpDiscoveryEngine) Stop(ctx context.Context) error {
	log.Println("Stopping SnmpDiscoveryEngine...")

	// Signal all goroutines to stop
	close(e.done)

	// Wait for all goroutines to finish
	// Use a timeout to prevent hanging indefinitely
	waitChan := make(chan struct{})
	go func() {
		e.wg.Wait()
		close(waitChan)
	}()

	select {
	case <-waitChan:
		log.Println("All SnmpDiscoveryEngine goroutines stopped.")
	case <-ctx.Done():
		log.Printf("SnmpDiscoveryEngine stop timed out or context cancelled: %v", ctx.Err())
		return ctx.Err()
	case <-time.After(10 * time.Second): // Fallback timeout
		log.Println("SnmpDiscoveryEngine stop timed out after 10s.")
		return fmt.Errorf("discovery engine stop timed out")
	}

	// Close jobChan after workers have stopped to prevent sending to closed channel
	close(e.jobChan)

	log.Println("SnmpDiscoveryEngine stopped.")
	return nil
}

// StartDiscovery initiates a discovery operation with the given parameters
func (e *SnmpDiscoveryEngine) StartDiscovery(ctx context.Context, params *DiscoveryParams) (string, error) {
	e.mu.Lock()
	// Intentionally not using defer e.mu.Unlock() here because of the select block
	// that might block. We will unlock manually before returning or if an error occurs early.

	discoveryID := uuid.New().String()
	// Create a new context for this specific job, derived from the incoming context.
	// This allows the job to be cancelled independently or if the parent ctx is cancelled.
	jobSpecificCtx, cancelFunc := context.WithCancel(ctx)

	job := &DiscoveryJob{
		ID:     discoveryID,
		Params: params,
		Status: &DiscoveryStatus{
			DiscoveryID: discoveryID,
			Status:      DiscoveryStatusPending,
			StartTime:   time.Now(),
			Progress:    0.0,
		},
		Results: &DiscoveryResults{
			DiscoveryID: discoveryID,
			Devices:     []*DiscoveredDevice{},
			Interfaces:  []*DiscoveredInterface{},
			RawData:     make(map[string]interface{}),
		},
		ctx:           jobSpecificCtx, // Assign the job-specific context here
		cancelFunc:    cancelFunc,
		discoveredIPs: make(map[string]bool),
		// scanQueue will be populated by the worker
	}

	// Check if we can accept new jobs based on the map size first (primary gate)
	if len(e.activeJobs) >= e.config.MaxActiveJobs {
		e.mu.Unlock() // Unlock before potentially blocking or returning
		cancelFunc()  // Cancel the job's context as it won't be processed
		log.Printf("Discovery engine at capacity (MaxActiveJobs map limit), job %s rejected.", discoveryID)
		return "", fmt.Errorf("discovery engine at capacity, please try again later")
	}

	// Try to send to jobChan (secondary gate, indicates worker availability)
	select {
	case e.jobChan <- job:
		// Job submitted successfully
		e.activeJobs[discoveryID] = job // Add to active jobs *after* successfully sending to channel
		e.mu.Unlock()                   // Unlock after all shared state modification
		log.Printf("Discovery job %s submitted with %d seeds.", discoveryID, len(params.Seeds))
		return discoveryID, nil
	case <-ctx.Done(): // Incoming request context cancelled
		e.mu.Unlock()
		cancelFunc() // Clean up the job-specific context
		log.Printf("Job %s submission cancelled because parent context was done: %v", discoveryID, ctx.Err())
		return "", ctx.Err()
	case <-e.done: // Engine is shutting down
		e.mu.Unlock()
		cancelFunc() // Clean up the job-specific context
		log.Printf("Job %s submission failed because engine is shutting down.", discoveryID)
		return "", fmt.Errorf("discovery engine is shutting down")
	default: // jobChan is full, workers are at capacity
		e.mu.Unlock()
		cancelFunc() // Clean up the job-specific context
		log.Printf("Discovery engine at capacity (jobChan full), job %s rejected.", discoveryID)
		return "", fmt.Errorf("discovery engine at capacity (workers busy), please try again later")
	}
}

// GetDiscoveryStatus retrieves the status of a discovery operation
func (e *SnmpDiscoveryEngine) GetDiscoveryStatus(ctx context.Context, discoveryID string) (*DiscoveryStatus, error) {
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

	return nil, fmt.Errorf("discovery job %s not found", discoveryID)
}

// GetDiscoveryResults retrieves the results of a completed discovery operation
func (e *SnmpDiscoveryEngine) GetDiscoveryResults(ctx context.Context, discoveryID string, includeRawData bool) (*DiscoveryResults, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if results, ok := e.completedJobs[discoveryID]; ok {
		// Return a copy. If includeRawData is false, nil out the RawData.
		// For simplicity, we'll return it as is for now, or you can make a deep copy.
		resultsCopy := *results
		if !includeRawData {
			resultsCopy.RawData = nil // Or an empty map: make(map[string]interface{})
		}
		return &resultsCopy, nil
	}

	if job, ok := e.activeJobs[discoveryID]; ok {
		return nil, fmt.Errorf("discovery job %s is still active, status: %s", discoveryID, job.Status.Status)
	}

	return nil, fmt.Errorf("discovery job %s not found or not completed", discoveryID)
}

// CancelDiscovery cancels an in-progress discovery operation
func (e *SnmpDiscoveryEngine) CancelDiscovery(ctx context.Context, discoveryID string) error {
	e.mu.Lock()
	job, ok := e.activeJobs[discoveryID]
	if !ok {
		e.mu.Unlock()
		// Check if already completed and cancelled
		if compJob, compOk := e.completedJobs[discoveryID]; compOk {
			if compJob.Status.Status == DiscoveryStatusCancelled {
				return nil // Already cancelled
			}
		}
		return fmt.Errorf("discovery job %s not found or not active", discoveryID)
	}
	// Job is active, proceed to cancel under lock
	job.cancelFunc() // Signal the job's context to cancel

	job.Status.Status = DiscoveryStatusCancelled
	job.Status.EndTime = time.Now()
	job.Status.Error = "Job cancelled by user"
	job.Status.Progress = 100 // Or current progress if preferred

	// Move to completed jobs
	e.completedJobs[discoveryID] = job.Results       // Store the partial/final results
	e.completedJobs[discoveryID].Status = job.Status // Ensure status in completedJobs is also updated
	delete(e.activeJobs, discoveryID)
	e.mu.Unlock()

	log.Printf("Discovery job %s cancelled.", discoveryID)
	return nil
}

// worker processes discovery jobs from jobChan
func (e *SnmpDiscoveryEngine) worker(ctx context.Context, workerID int) {
	defer e.wg.Done()
	log.Printf("Discovery worker %d started.", workerID)

	for {
		select {
		case <-ctx.Done(): // Main context cancelled
			log.Printf("Discovery worker %d stopping due to main context cancellation.", workerID)
			return
		case <-e.done: // Engine stopping
			log.Printf("Discovery worker %d stopping due to engine shutdown.", workerID)
			return
		case job, ok := <-e.jobChan:
			if !ok { // jobChan was closed
				log.Printf("Discovery worker %d stopping as job channel was closed.", workerID)
				return
			}

			// Use the job-specific context provided when it was created
			jobSpecificCtx := job.cancelFunc // This is actually the context.Context for the job
			_ = jobSpecificCtx               // Avoid unused variable if not directly used here

			log.Printf("Worker %d picked up job %s.", workerID, job.ID)
			job.Status.Status = DiscoveryStatusRunning
			job.Status.Progress = 5 // Indicate it's started

			// Placeholder for actual discovery logic
			e.runDiscoveryJob(job) // Pass job.ctx here

			// After job execution (success, failure, or cancellation handled within runDiscoveryJob)
			e.mu.Lock()
			if _, isActive := e.activeJobs[job.ID]; isActive { // Check if not already cancelled and moved
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
			log.Printf("Worker %d finished job %s with status %s.", workerID, job.ID, job.Status.Status)
		}
	}
}

// runDiscoveryJob is a placeholder for the actual SNMP discovery logic for a job.
// It should update job.Status and job.Results.
// It should also respect job.cancelFunc (job's context).
func (e *SnmpDiscoveryEngine) runDiscoveryJob(job *DiscoveryJob) {
	log.Printf("Running discovery for job %s. Seeds: %v, Type: %s", job.ID, job.Params.Seeds, job.Params.Type)

	// Example: Simulate work and check for cancellation
	totalSteps := 10
	for i := 0; i < totalSteps; i++ {
		select {
		case <-job.ctx.Done(): // Check if the job-specific context was cancelled
			log.Printf("Job %s cancelled during execution.", job.ID)
			job.Status.Status = DiscoveryStatusCancelled
			job.Status.Error = "Job execution cancelled"
			job.Status.Progress = float64(i+1) / float64(totalSteps) * 100
			return
		case <-e.done: // Engine stopping
			log.Printf("Job %s interrupted due to engine shutdown.", job.ID)
			job.Status.Status = DiscoveryStatusFailed // Or Cancelled, depending on policy
			job.Status.Error = "Engine shutting down"
			job.Status.Progress = float64(i+1) / float64(totalSteps) * 100
			return
		default:
			// Simulate doing some work
			time.Sleep(500 * time.Millisecond) // Represents a part of the discovery scan
			job.mu.Lock()
			job.Status.Progress = float64(i+1) / float64(totalSteps) * 100
			// Example: add a dummy device
			if i%2 == 0 {
				dummyDevice := &DiscoveredDevice{
					IP:       fmt.Sprintf("192.168.1.%d", i+1),
					Hostname: fmt.Sprintf("device-%d", i+1),
					SysDescr: "Simulated Device",
				}
				job.Results.Devices = append(job.Results.Devices, dummyDevice)
				if e.publisher != nil {
					// It's good practice to use the job's context for publishing too
					if err := e.publisher.PublishDevice(job.ctx, dummyDevice); err != nil {
						log.Printf("Job %s: Failed to publish device %s: %v", job.ID, dummyDevice.IP, err)
					}
				}
			}
			job.mu.Unlock()
			log.Printf("Job %s progress: %.2f%%", job.ID, job.Status.Progress)
		}
	}

	job.mu.Lock()
	if job.Status.Status == DiscoveryStatusRunning { // Check if not cancelled
		job.Status.Status = DiscoveryStatusCompleted
		job.Status.Progress = 100
		log.Printf("Job %s completed successfully.", job.ID)
	}
	job.mu.Unlock()
}

// validateConfig checks that the provided configuration is valid
func validateConfig(config *Config) error {
	if config == nil {
		return fmt.Errorf("config cannot be nil")
	}
	if config.Workers <= 0 {
		return fmt.Errorf("workers must be greater than 0, got %d", config.Workers)
	}
	if config.MaxActiveJobs <= 0 {
		return fmt.Errorf("maxActiveJobs must be greater than 0, got %d", config.MaxActiveJobs)
	}
	if config.Timeout <= 0 {
		config.Timeout = 30 * time.Second // Default timeout
		log.Printf("Discovery config: Timeout not set or invalid, defaulting to %v", config.Timeout)
	}
	if config.ResultRetention <= 0 {
		config.ResultRetention = 24 * time.Hour // Default retention
		log.Printf("Discovery config: ResultRetention not set or invalid, defaulting to %v", config.ResultRetention)
	}
	// Further checks for OIDs, StreamConfig etc. can be added here
	return nil
}

// Add this to SnmpDiscoveryEngine struct in types.go
// wg sync.WaitGroup

// Modify DiscoveryJob struct in types.go
// ctx context.Context // Add this line for job-specific context
