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

// Package mapper pkg/discovery/discovery.go
package mapper

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/google/uuid"
)

// NewDiscoveryEngine creates a new discovery engine with the given configuration
func NewDiscoveryEngine(config *Config, publisher Publisher, log logger.Logger) (Mapper, error) {
	if err := validateConfig(config); err != nil {
		return nil, fmt.Errorf("invalid discovery engine configuration: %w", err)
	}

	engine := &DiscoveryEngine{
		config:        config,
		activeJobs:    make(map[string]*DiscoveryJob),
		completedJobs: make(map[string]*DiscoveryResults),
		jobChan:       make(chan *DiscoveryJob, config.MaxActiveJobs),
		workers:       config.Workers,
		publisher:     publisher,
		done:          make(chan struct{}),
		schedulers:    make(map[string]*time.Ticker),
		logger:        log,
	}

	return engine, nil
}

// Start initializes and starts the discovery engine
func (e *DiscoveryEngine) Start(ctx context.Context) error {
	e.logger.Info().
		Int("workers", e.workers).
		Int("max_active_jobs", e.config.MaxActiveJobs).
		Msg("Starting DiscoveryEngine")

	e.wg.Add(e.workers) // Add worker count to WaitGroup

	for i := 0; i < e.workers; i++ {
		go e.worker(ctx, i)
	}

	// Start cleanup routine for completed jobs
	e.wg.Add(1)

	go func() {
		defer e.wg.Done()
		e.cleanupRoutine(ctx)
	}()

	// Start scheduled jobs
	e.wg.Add(1)

	go func() {
		defer e.wg.Done()
		e.scheduleJobs(ctx)
	}()

	e.logger.Info().Msg("DiscoveryEngine started")

	return nil
}

const (
	defaultFallbackTimeout = 10 * time.Second // Fallback timeout for stopping
)

// Stop gracefully shuts down the discovery engine
func (e *DiscoveryEngine) Stop(ctx context.Context) error {
	e.logger.Info().Msg("Stopping DiscoveryEngine")

	// Stop all schedulers
	e.mu.Lock()
	for name, ticker := range e.schedulers {
		ticker.Stop()
		e.logger.Info().Str("job", name).Msg("Stopped scheduler for job")
	}

	e.schedulers = make(map[string]*time.Ticker) // Reset schedulers
	e.mu.Unlock()

	// Signal all goroutines to stop
	close(e.done)

	// Wait for all goroutines to finish
	waitChan := make(chan struct{})

	go func() {
		e.wg.Wait()
		close(waitChan)
	}()

	select {
	case <-waitChan:
		e.logger.Info().Msg("All DiscoveryEngine goroutines stopped")
	case <-ctx.Done():
		e.logger.Error().Err(ctx.Err()).Msg("DiscoveryEngine stop timed out or context canceled")
		return ctx.Err()
	case <-time.After(defaultFallbackTimeout):
		e.logger.Error().Msg("DiscoveryEngine stop timed out after 10s")
		return ErrDiscoveryStopTimeout
	}

	// Close jobChan after workers have stopped
	close(e.jobChan)

	e.logger.Info().Msg("DiscoveryEngine stopped")

	return nil
}

// scheduleJobs starts tickers for each enabled scheduled job
func (e *DiscoveryEngine) scheduleJobs(ctx context.Context) {
	e.logger.Info().Msg("Starting scheduled jobs")

	for i := range e.config.ScheduledJobs {
		jobConfig := e.config.ScheduledJobs[i]
		if !jobConfig.Enabled {
			e.logger.Info().Str("job", jobConfig.Name).Msg("Scheduled job is disabled, skipping")
			continue
		}

		interval, err := time.ParseDuration(jobConfig.Interval)
		if err != nil {
			e.logger.Error().Str("job", jobConfig.Name).Err(err).
				Msg("Invalid interval for job, skipping")
			continue
		}

		if interval <= 0 {
			e.logger.Error().Str("job", jobConfig.Name).
				Msg("Invalid interval for job: must be positive, skipping")
			continue
		}

		timeout, err := time.ParseDuration(jobConfig.Timeout)
		if err != nil {
			e.logger.Warn().Str("job", jobConfig.Name).Err(err).
				Msg("Invalid timeout for job, using default config timeout")

			timeout = e.config.Timeout
		}

		// Map job type to DiscoveryType
		var discoveryType DiscoveryType

		switch jobConfig.Type {
		case "full":
			discoveryType = DiscoveryTypeFull
		case "basic":
			discoveryType = DiscoveryTypeBasic
		case "interfaces":
			discoveryType = DiscoveryTypeInterfaces
		case "topology":
			discoveryType = DiscoveryTypeTopology
		default:
			e.logger.Error().Str("job", jobConfig.Name).Str("type", jobConfig.Type).
				Msg("Invalid type for job, skipping")
			continue
		}

		params := &DiscoveryParams{
			Seeds:       jobConfig.Seeds,
			Type:        discoveryType,
			Credentials: &(jobConfig.Credentials),
			Options:     jobConfig.Options,
			Concurrency: jobConfig.Concurrency,
			Timeout:     timeout,
			Retries:     jobConfig.Retries,
			AgentID:     e.config.StreamConfig.AgentID,
			PollerID:    e.config.StreamConfig.PollerID,
		}

		// Start the job immediately
		e.startScheduledJob(ctx, jobConfig.Name, params)

		// Create ticker for periodic execution
		ticker := time.NewTicker(interval)

		e.mu.Lock()
		e.schedulers[jobConfig.Name] = ticker
		e.mu.Unlock()

		e.wg.Add(1)

		go func(name string, params *DiscoveryParams) {
			defer e.wg.Done()

			e.logger.Info().Str("job", name).Dur("interval", interval).Msg("Scheduler started for job")

			for {
				select {
				case <-ctx.Done():
					e.logger.Info().Str("job", name).Msg("Scheduler stopping due to context cancellation")
					ticker.Stop()

					return
				case <-e.done:
					e.logger.Info().Str("job", name).Msg("Scheduler stopping due to engine shutdown")
					ticker.Stop()

					return
				case <-ticker.C:
					e.startScheduledJob(ctx, name, params)
				}
			}
		}(jobConfig.Name, params)
	}

	e.logger.Info().Msg("All scheduled jobs initialized")
}

// startScheduledJob initiates a discovery job
func (e *DiscoveryEngine) startScheduledJob(ctx context.Context, name string, params *DiscoveryParams) {
	e.logger.Info().Str("job", name).Msg("Starting scheduled job")

	discoveryID, err := e.StartDiscovery(ctx, params)
	if err != nil {
		e.logger.Error().Str("job", name).Err(err).Msg("Failed to start scheduled job")
		return
	}

	// Add job name to job metadata
	e.mu.RLock()
	if job, exists := e.activeJobs[discoveryID]; exists {
		job.Results.RawData["scheduled_job_name"] = name
		job.Results.RawData["agent_id"] = params.AgentID
		job.Results.RawData["poller_id"] = params.PollerID
	}
	e.mu.RUnlock()

	e.logger.Info().Str("job", name).Str("discovery_id", discoveryID).
		Msg("Scheduled job started with discovery ID")
}

// StartDiscovery initiates a discovery operation with the given parameters.
func (e *DiscoveryEngine) StartDiscovery(ctx context.Context, params *DiscoveryParams) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Validate params
	if len(params.Seeds) == 0 {
		return "", fmt.Errorf("no seeds provided")
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
		RawData:       make(map[string]interface{}),
	}

	// Initialize RawData with AgentID and PollerID
	results.RawData["agent_id"] = params.AgentID
	results.RawData["poller_id"] = params.PollerID

	job := &DiscoveryJob{
		ID:         discoveryID,
		Params:     params,
		Results:    results,
		Status:     results.Status, // Point to the same status
		ctx:        jobCtx,
		cancelFunc: cancel,
		deviceMap:  make(map[string]*DeviceInterfaceMap),
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

		return "", fmt.Errorf("job queue full, cannot enqueue discovery job")
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
		// Return a copy. If includeRawData is false, nil out the RawData.
		// For simplicity, we'll return it as is for now, or you can make a deep copy.
		resultsCopy := *results
		if !includeRawData {
			resultsCopy.RawData = nil // Or an empty map: make(map[string]interface{})
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

const (
	defaultTimeout         = 30 * time.Second
	defaultResultRetention = 24 * time.Hour
)

// validateConfig checks that the provided configuration is valid.
func validateConfig(config *Config) error {
	if config == nil {
		return ErrConfigNil
	}

	if config.Workers <= 0 {
		return fmt.Errorf("%w: got %d", ErrInvalidWorkers, config.Workers)
	}

	if config.MaxActiveJobs <= 0 {
		return fmt.Errorf("%w: got %d", ErrInvalidMaxActiveJobs, config.MaxActiveJobs)
	}

	if config.Timeout <= 0 {
		config.Timeout = defaultTimeout
	}

	if config.ResultRetention <= 0 {
		config.ResultRetention = defaultResultRetention
	}

	// Validate scheduled jobs
	for i := range config.ScheduledJobs {
		if err := validateScheduledJob(config.ScheduledJobs[i]); err != nil {
			return err
		}
	}

	return nil
}

// validateScheduledJob validates a single scheduled job configuration
func validateScheduledJob(job *ScheduledJob) error {
	if job.Name == "" {
		return fmt.Errorf("scheduled job missing name")
	}

	if !job.Enabled {
		return nil
	}

	if _, err := time.ParseDuration(job.Interval); err != nil {
		return fmt.Errorf("invalid interval for job %s: %w", job.Name, err)
	}

	if len(job.Seeds) == 0 {
		return fmt.Errorf("job %s has no seeds", job.Name)
	}

	if job.Type == "" {
		return fmt.Errorf("job %s missing type", job.Name)
	}

	// Validate that job.Type is one of the valid DiscoveryType values
	validTypes := map[string]bool{
		string(DiscoveryTypeFull):       true,
		string(DiscoveryTypeBasic):      true,
		string(DiscoveryTypeInterfaces): true,
		string(DiscoveryTypeTopology):   true,
	}
	if !validTypes[job.Type] {
		return fmt.Errorf("job %s has invalid type: %s", job.Name, job.Type)
	}

	if job.Concurrency < 0 {
		return fmt.Errorf("job %s has invalid concurrency: %d", job.Name, job.Concurrency)
	}

	if job.Retries < 0 {
		return fmt.Errorf("job %s has invalid retries: %d", job.Name, job.Retries)
	}

	if job.Timeout != "" {
		if _, err := time.ParseDuration(job.Timeout); err != nil {
			return fmt.Errorf("invalid timeout for job %s: %w", job.Name, err)
		}
	}

	return nil
}

// initializeDevice creates and initializes a new DiscoveredDevice
func (*DiscoveryEngine) initializeDevice(target string) *DiscoveredDevice {
	return &DiscoveredDevice{
		IP:        target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
		Metadata:  make(map[string]string),
	}
}

// publishTopologyLinks adds topology links to results and publishes them
func (e *DiscoveryEngine) publishTopologyLinks(job *DiscoveryJob, links []*TopologyLink, target, protocol string) {
	if len(links) == 0 {
		return
	}

	job.mu.Lock()
	job.Results.TopologyLinks = append(job.Results.TopologyLinks, links...)
	job.mu.Unlock()

	// Publish links
	if e.publisher != nil {
		for _, link := range links {
			if err := e.publisher.PublishTopologyLink(job.ctx, link); err != nil {
				e.logger.Error().Str("job_id", job.ID).Str("protocol", protocol).
					Str("target", target).Int32("if_index", link.LocalIfIndex).
					Err(err).Msg("Failed to publish link")
			}
		}
	}
}

// handleEmptyTargetList updates job status when no valid targets are found
func (e *DiscoveryEngine) handleEmptyTargetList(job *DiscoveryJob) {
	job.mu.Lock()
	job.Status.Status = DiscoveryStatusFailed
	job.Status.Error = "No valid targets to scan after processing seeds"
	job.Status.Progress = 100
	job.mu.Unlock()

	e.logger.Error().Str("job_id", job.ID).Msg("Failed - no valid targets to scan")
}

// determineConcurrency calculates the appropriate concurrency level.
func (e *DiscoveryEngine) determineConcurrency(job *DiscoveryJob, totalTargets int) int {
	concurrency := job.Params.Concurrency

	if concurrency <= 0 {
		// For small target lists (5 or fewer), use the target count
		// For large target lists (more than 5), use the worker count
		if totalTargets <= 5 {
			concurrency = totalTargets
		} else {
			concurrency = e.workers
		}
	}

	if concurrency > totalTargets {
		concurrency = totalTargets // Don't create more workers than needed
	}

	return concurrency
}

type targetProcessorFunc func(job *DiscoveryJob, targetIP string)

// startWorkers launches worker goroutines to process targets using the provided processor function.
func (e *DiscoveryEngine) startWorkers(
	job *DiscoveryJob,
	wg *sync.WaitGroup,
	targetChan <-chan string,
	resultChan chan<- bool,
	concurrency int,
	processor targetProcessorFunc,
) {
	for i := 0; i < concurrency; i++ {
		wg.Add(1)

		go func(workerID int) {
			defer wg.Done()

			for target := range targetChan {
				success := false

				select {
				case <-job.ctx.Done():
					e.logger.Info().Str("job_id", job.ID).Int("worker_id", workerID).
						Str("target", target).Msg("Worker stopping")
					return
				case <-e.done:
					e.logger.Info().Str("job_id", job.ID).Int("worker_id", workerID).
						Msg("Worker stopping - engine shutdown")
					return
				default:
					// Ping with timeout
					pingCtx, pingCancel := context.WithTimeout(job.ctx, 5*time.Second)
					pingErr := pingHost(pingCtx, target)

					pingCancel()

					if pingErr != nil {
						e.logger.Debug().Str("job_id", job.ID).
							Str("target", target).
							Err(pingErr).
							Msg("Host ping failed")
						// Send result for failed ping
						select {
						case resultChan <- success:
						default:
						}

						continue // Process next target
					}

					// Process target with overall timeout
					targetCtx, targetCancel := context.WithTimeout(job.ctx, 2*time.Minute)

					targetDone := make(chan struct{})
					go func() {
						processor(job, target)
						close(targetDone)
					}()

					select {
					case <-targetDone:
						success = true
					case <-targetCtx.Done():
						e.logger.Warn().Str("job_id", job.ID).
							Int("worker_id", workerID).
							Str("target", target).
							Msg("Worker timeout")

						success = false
					}

					targetCancel()

					// Send result after processing target
					select {
					case resultChan <- success:
					default:
					}
				}
			}

			e.logger.Debug().Str("job_id", job.ID).Int("worker_id", workerID).Msg("Worker finished")
		}(i)
	}
}

// feedTargetsToWorkers sends targets to worker goroutines
// Returns true if job was canceled during feeding
func (e *DiscoveryEngine) feedTargetsToWorkers(job *DiscoveryJob, targetChan chan<- string) bool {
	for _, target := range job.scanQueue {
		select {
		case targetChan <- target:
			// Target sent to worker
		case <-job.ctx.Done():
			e.logger.Info().Str("job_id", job.ID).Msg("Stopping target feed due to cancellation")
			close(targetChan)

			return true
		case <-e.done:
			e.logger.Info().Str("job_id", job.ID).Msg("Stopping target feed due to engine shutdown")
			close(targetChan)

			return true
		}
	}

	close(targetChan)

	return false
}

// checkJobCancellation checks if the job was canceled or the engine is shutting down
// Returns true if the job was canceled
func (e *DiscoveryEngine) checkPhaseJobCancellation(job *DiscoveryJob, seedIP, phaseName string) bool {
	select {
	case <-job.ctx.Done():
		e.logger.Info().Str("job_id", job.ID).
			Str("phase", phaseName).
			Str("seed_ip", seedIP).
			Err(job.ctx.Err()).
			Msg("Phase canceled for seed")
		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoverStatusCanceled
			job.Status.Error = fmt.Sprintf("Job canceled during %s phase: %v", phaseName, job.ctx.Err())
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()

		return true
	case <-e.done:
		e.logger.Info().Str("job_id", job.ID).
			Str("phase", phaseName).
			Str("seed_ip", seedIP).
			Msg("Phase stopped due to engine shutdown for seed")
		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoveryStatusFailed
			job.Status.Error = fmt.Sprintf("Engine shutting down during %s phase", phaseName)
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()

		return true
	default:
		return false
	}
}

// finalizeJobStatus updates the job status after completion
func (e *DiscoveryEngine) finalizeJobStatus(job *DiscoveryJob) {
	job.mu.Lock()
	defer job.mu.Unlock()

	if job.Status.Status == DiscoveryStatusRunning {
		// Step 1: Deduplicate devices using the device map
		e.deduplicateDevices(job)

		// Step 2: Update status
		job.Status.Status = DiscoveryStatusCompleted
		job.Status.Progress = progressCompleted

		if len(job.Results.Devices) == 0 {
			job.Status.Error = "No SNMP devices found"
			e.logger.Info().Str("job_id", job.ID).Msg("Completed - no SNMP devices found")
		} else {
			e.logger.Info().Str("job_id", job.ID).
				Int("devices", len(job.Results.Devices)).
				Int("interfaces", len(job.Results.Interfaces)).
				Int("topology_links", len(job.Results.TopologyLinks)).
				Msg("Completed successfully")
		}
	}
}

// deviceGroup represents a group of devices that might be the same based on shared attributes
type deviceGroup struct {
	DeviceIDs map[string]struct{}
	MACs      map[string]struct{}
	IPs       map[string]struct{}
	SysName   string
}

func (e *DiscoveryEngine) deduplicateDevices(job *DiscoveryJob) {
	// Step 1: Group devices by shared attributes
	deviceGroups := e.buildDeviceGroups(job)

	// Step 2: Use topology links to further merge groups
	deviceGroups = e.mergeGroupsByTopologyLinks(job, deviceGroups)

	// Step 3: Rebuild the device list
	newDevices := e.rebuildDeviceList(job, deviceGroups)

	// Step 4: Update interfaces to point to the primary DeviceID
	e.updateInterfaceDeviceIDs(job, deviceGroups)

	// Update the results
	job.Results.Devices = newDevices
}

// buildDeviceGroups groups devices by shared attributes (IPs, MACs, system names)
func (e *DiscoveryEngine) buildDeviceGroups(job *DiscoveryJob) map[string]*deviceGroup {
	deviceGroups := make(map[string]*deviceGroup) // Primary DeviceID -> group

	for deviceID, deviceEntry := range job.deviceMap {
		matchedGroupID := e.findMatchingGroup(deviceGroups, deviceEntry)

		if matchedGroupID == "" {
			// Create a new group
			deviceGroups[deviceID] = e.createNewDeviceGroup(deviceID, deviceEntry)
		} else {
			// Merge into existing group
			e.mergeIntoExistingGroup(deviceGroups[matchedGroupID], deviceID, deviceEntry)
		}
	}

	return deviceGroups
}

// findMatchingGroup finds a matching device group based on shared attributes
func (*DiscoveryEngine) findMatchingGroup(deviceGroups map[string]*deviceGroup, deviceEntry *DeviceInterfaceMap) string {
	for groupID, group := range deviceGroups {
		// Match by shared IP
		for ip := range deviceEntry.IPs {
			if _, exists := group.IPs[ip]; exists {
				return groupID
			}
		}

		// Match by shared MAC
		for mac := range deviceEntry.MACs {
			if _, exists := group.MACs[mac]; exists {
				return groupID
			}
		}

		// Match by system name (if non-empty)
		if deviceEntry.SysName != "" && group.SysName == deviceEntry.SysName {
			return groupID
		}
	}

	return ""
}

// createNewDeviceGroup creates a new device group for a device
func (*DiscoveryEngine) createNewDeviceGroup(deviceID string, deviceEntry *DeviceInterfaceMap) *deviceGroup {
	group := &deviceGroup{
		DeviceIDs: map[string]struct{}{deviceID: {}},
		MACs:      make(map[string]struct{}),
		IPs:       make(map[string]struct{}),
		SysName:   deviceEntry.SysName,
	}

	for mac := range deviceEntry.MACs {
		group.MACs[mac] = struct{}{}
	}

	for ip := range deviceEntry.IPs {
		group.IPs[ip] = struct{}{}
	}

	return group
}

// mergeIntoExistingGroup merges a device into an existing group
func (*DiscoveryEngine) mergeIntoExistingGroup(group *deviceGroup, deviceID string, deviceEntry *DeviceInterfaceMap) {
	group.DeviceIDs[deviceID] = struct{}{}

	for mac := range deviceEntry.MACs {
		group.MACs[mac] = struct{}{}
	}

	for ip := range deviceEntry.IPs {
		group.IPs[ip] = struct{}{}
	}

	if group.SysName == "" && deviceEntry.SysName != "" {
		group.SysName = deviceEntry.SysName
	}
}

// mergeGroupsByTopologyLinks uses topology links to further merge device groups
func (e *DiscoveryEngine) mergeGroupsByTopologyLinks(job *DiscoveryJob, deviceGroups map[string]*deviceGroup) map[string]*deviceGroup {
	for _, link := range job.Results.TopologyLinks {
		localDeviceID := e.findDeviceIDByIP(job, link.LocalDeviceIP)
		neighborDeviceID := e.findDeviceIDByIP(job, link.NeighborMgmtAddr)

		if localDeviceID != "" && neighborDeviceID != "" && localDeviceID != neighborDeviceID {
			localGroupID := e.findGroupIDForDevice(deviceGroups, localDeviceID)
			neighborGroupID := e.findGroupIDForDevice(deviceGroups, neighborDeviceID)

			if localGroupID != neighborGroupID && localGroupID != "" && neighborGroupID != "" {
				// Merge the groups
				e.mergeDeviceGroups(deviceGroups, localGroupID, neighborGroupID)
			}
		}
	}

	return deviceGroups
}

// findDeviceIDByIP finds a device ID by its IP address
func (*DiscoveryEngine) findDeviceIDByIP(job *DiscoveryJob, ip string) string {
	for deviceID, deviceEntry := range job.deviceMap {
		if _, exists := deviceEntry.IPs[ip]; exists {
			return deviceID
		}
	}

	return ""
}

// findGroupIDForDevice finds the group ID for a device
func (*DiscoveryEngine) findGroupIDForDevice(deviceGroups map[string]*deviceGroup, deviceID string) string {
	for groupID, group := range deviceGroups {
		if _, exists := group.DeviceIDs[deviceID]; exists {
			return groupID
		}
	}

	return ""
}

// mergeDeviceGroups merges two device groups
func (*DiscoveryEngine) mergeDeviceGroups(deviceGroups map[string]*deviceGroup, targetGroupID, sourceGroupID string) {
	targetGroup := deviceGroups[targetGroupID]
	sourceGroup := deviceGroups[sourceGroupID]

	for deviceID := range sourceGroup.DeviceIDs {
		targetGroup.DeviceIDs[deviceID] = struct{}{}
	}

	for mac := range sourceGroup.MACs {
		targetGroup.MACs[mac] = struct{}{}
	}

	for ip := range sourceGroup.IPs {
		targetGroup.IPs[ip] = struct{}{}
	}

	if targetGroup.SysName == "" && sourceGroup.SysName != "" {
		targetGroup.SysName = sourceGroup.SysName
	}

	delete(deviceGroups, sourceGroupID)
}

// rebuildDeviceList rebuilds the device list with merged metadata
func (e *DiscoveryEngine) rebuildDeviceList(job *DiscoveryJob, deviceGroups map[string]*deviceGroup) []*DiscoveredDevice {
	newDevices := make([]*DiscoveredDevice, 0)

	for primaryDeviceID, group := range deviceGroups {
		primaryDevice := e.findPrimaryDevice(job, primaryDeviceID)

		if primaryDevice == nil {
			continue
		}

		e.mergeDeviceMetadata(job, primaryDevice, group)
		newDevices = append(newDevices, primaryDevice)
	}

	return newDevices
}

// findPrimaryDevice finds the primary device by its ID
func (*DiscoveryEngine) findPrimaryDevice(job *DiscoveryJob, primaryDeviceID string) *DiscoveredDevice {
	for _, device := range job.Results.Devices {
		if device.DeviceID == primaryDeviceID {
			return device
		}
	}

	return nil
}

// mergeDeviceMetadata merges metadata from other devices in the group
func (e *DiscoveryEngine) mergeDeviceMetadata(job *DiscoveryJob, primaryDevice *DiscoveredDevice, group *deviceGroup) {
	for deviceID := range group.DeviceIDs {
		if deviceID == primaryDevice.DeviceID {
			continue
		}

		for _, device := range job.Results.Devices {
			if device.DeviceID == deviceID {
				e.copyMetadataToDevice(primaryDevice, device)
				e.addAlternateIPs(primaryDevice, group.IPs)
			}
		}
	}
}

// copyMetadataToDevice copies metadata from source device to target device
func (*DiscoveryEngine) copyMetadataToDevice(targetDevice, sourceDevice *DiscoveredDevice) {
	for k, v := range sourceDevice.Metadata {
		if _, exists := targetDevice.Metadata[k]; !exists {
			if targetDevice.Metadata == nil {
				targetDevice.Metadata = make(map[string]string)
			}

			targetDevice.Metadata[k] = v
		}
	}
}

// addAlternateIPs adds alternate IPs to device metadata
func (*DiscoveryEngine) addAlternateIPs(device *DiscoveredDevice, ips map[string]struct{}) {
	for ip := range ips {
		if ip != device.IP {
			device.Metadata = addAlternateIP(device.Metadata, ip)
		}
	}
}

// updateInterfaceDeviceIDs updates interfaces to point to the primary DeviceID
func (*DiscoveryEngine) updateInterfaceDeviceIDs(job *DiscoveryJob, deviceGroups map[string]*deviceGroup) {
	for _, iface := range job.Results.Interfaces {
		for groupID, group := range deviceGroups {
			if _, exists := group.IPs[iface.DeviceIP]; exists {
				iface.DeviceID = groupID
				break
			}
		}
	}
}

const (
	defaultConcurrencyMultiplier = 2 // Multiplier for target channel size
)

// addOrUpdateDeviceToResults adds or updates a device in the job's results.
func (e *DiscoveryEngine) addOrUpdateDeviceToResults(job *DiscoveryJob, newDevice *DiscoveredDevice) {
	e.ensureDeviceID(newDevice)

	// Look for an existing device to merge with
	for i, existingDevice := range job.Results.Devices {
		if e.isDeviceMatch(existingDevice, newDevice) {
			e.updateExistingDevice(job, i, newDevice)

			if existingDevice.IP != newDevice.IP {
				existingDevice.Metadata = addAlternateIP(existingDevice.Metadata, newDevice.IP)

				e.logger.Info().Str("job_id", job.ID).
					Str("hostname", existingDevice.Hostname).
					Str("mac", existingDevice.MAC).
					Str("device_id", existingDevice.DeviceID).
					Str("alternate_ip", newDevice.IP).
					Str("primary_ip", existingDevice.IP).
					Str("source", newDevice.Metadata["source"]).
					Msg("Device updated with alternate IP")
			}

			return
		}
	}

	// Add to device map
	if deviceEntry, exists := job.deviceMap[newDevice.DeviceID]; exists {
		deviceEntry.MACs[newDevice.MAC] = struct{}{}
		deviceEntry.IPs[newDevice.IP] = struct{}{}

		if newDevice.Hostname != "" {
			deviceEntry.SysName = newDevice.Hostname
		}
	} else {
		job.deviceMap[newDevice.DeviceID] = &DeviceInterfaceMap{
			DeviceID:   newDevice.DeviceID,
			MACs:       map[string]struct{}{newDevice.MAC: {}},
			IPs:        map[string]struct{}{newDevice.IP: {}},
			SysName:    newDevice.Hostname,
			Interfaces: []*DiscoveredInterface{},
		}
	}

	e.logger.Info().Str("job_id", job.ID).Str("hostname", newDevice.Hostname).
		Str("ip", newDevice.IP).Str("mac", newDevice.MAC).
		Str("device_id", newDevice.DeviceID).
		Str("source", newDevice.Metadata["source"]).
		Msg("Adding new device")

	e.addNewDevice(job, newDevice)
}

// ensureDeviceID ensures the DeviceID is populated if possible
func (*DiscoveryEngine) ensureDeviceID(device *DiscoveredDevice) {
	if device.DeviceID == "" && device.MAC != "" {
		device.DeviceID = GenerateDeviceID(device.MAC)
	} else if device.DeviceID == "" {
		device.DeviceID = GenerateDeviceIDFromIP(device.IP)
	}
}

func (*DiscoveryEngine) isDeviceMatch(existingDevice, newDevice *DiscoveredDevice) bool {
	// First check by DeviceID if both have it
	if newDevice.DeviceID != "" && existingDevice.DeviceID != "" && newDevice.DeviceID == existingDevice.DeviceID {
		return true
	}

	// Temporarily disable MAC-based matching until we build the interface-to-device map
	return false
}

// updateExistingDevice updates an existing device with information from a new device
func (e *DiscoveryEngine) updateExistingDevice(job *DiscoveryJob, index int, newDevice *DiscoveredDevice) {
	// Update non-empty fields
	if newDevice.Hostname != "" {
		job.Results.Devices[index].Hostname = newDevice.Hostname
	}

	if newDevice.MAC != "" {
		job.Results.Devices[index].MAC = newDevice.MAC
	}

	if newDevice.SysDescr != "" {
		job.Results.Devices[index].SysDescr = newDevice.SysDescr
	}

	if newDevice.SysObjectID != "" {
		job.Results.Devices[index].SysObjectID = newDevice.SysObjectID
	}

	if newDevice.SysContact != "" {
		job.Results.Devices[index].SysContact = newDevice.SysContact
	}

	if newDevice.SysLocation != "" {
		job.Results.Devices[index].SysLocation = newDevice.SysLocation
	}

	if newDevice.Uptime != 0 {
		job.Results.Devices[index].Uptime = newDevice.Uptime
	}

	job.Results.Devices[index].LastSeen = time.Now()

	// Update metadata
	e.updateDeviceMetadata(job, index, newDevice)

	// Publish updated device
	e.publishDevice(job, job.Results.Devices[index])
}

// updateDeviceMetadata updates the metadata of an existing device
func (*DiscoveryEngine) updateDeviceMetadata(job *DiscoveryJob, index int, newDevice *DiscoveredDevice) {
	if job.Results.Devices[index].Metadata == nil {
		job.Results.Devices[index].Metadata = make(map[string]string)
	}

	for k, v := range newDevice.Metadata {
		job.Results.Devices[index].Metadata[k] = v
	}
}

// addNewDevice adds a new device to the results
func (e *DiscoveryEngine) addNewDevice(job *DiscoveryJob, newDevice *DiscoveredDevice) {
	newDevice.FirstSeen = time.Now()
	newDevice.LastSeen = time.Now()
	job.Results.Devices = append(job.Results.Devices, newDevice)

	// Publish new device
	e.publishDevice(job, newDevice)
}

// publishDevice publishes a device via the publisher if available
func (e *DiscoveryEngine) publishDevice(job *DiscoveryJob, device *DiscoveredDevice) {
	if e.publisher != nil {
		if err := e.publisher.PublishDevice(job.ctx, device); err != nil {
			e.logger.Error().Str("job_id", job.ID).Str("device_ip", device.IP).
				Err(err).Msg("Failed to publish device")
		}
	}
}

// runDiscoveryJob performs the actual discovery for a job, now in two phases.
func (e *DiscoveryEngine) runDiscoveryJob(ctx context.Context, job *DiscoveryJob) {
	e.logger.Info().Str("job_id", job.ID).Strs("seeds", job.Params.Seeds).
		Str("type", string(job.Params.Type)).Msg("Running discovery for job")

	initialSeeds := e.expandSeeds(job.Params.Seeds)

	if len(initialSeeds) == 0 {
		e.handleEmptyTargetList(job)
		return
	}

	// Phase 1: UniFi Device Discovery
	allPotentialSNMPTargets := e.handleUniFiDiscoveryPhase(ctx, job, initialSeeds)

	if e.checkPhaseJobCancellation(job, "", "UniFi discovery") {
		e.logger.Info().Str("job_id", job.ID).Msg("UniFi Discovery phase was canceled")

		e.finalizeJobStatus(job)

		return
	}

	e.logger.Info().Str("job_id", job.ID).Msg("Transitioning to SNMP Polling phase")

	// Phase 2: SNMP Polling
	if allPotentialSNMPTargets == nil {
		allPotentialSNMPTargets = make(map[string]bool)
		for _, seed := range initialSeeds {
			allPotentialSNMPTargets[seed] = true
		}

		e.logger.Info().Str("job_id", job.ID).Strs("initial_seeds", initialSeeds).
			Msg("No UniFi targets found, falling back to initial seeds")
	}

	if !e.setupAndExecuteSNMPPolling(job, allPotentialSNMPTargets, initialSeeds) {
		e.logger.Warn().Str("job_id", job.ID).Msg("SNMP Polling phase failed or was canceled")
	}

	e.logger.Debug().Str("job_id", job.ID).Msg("Finalizing job status")

	e.finalizeJobStatus(job)
}

// handleUniFiDiscoveryPhase performs the UniFi discovery phase and collects potential SNMP targets
func (e *DiscoveryEngine) handleUniFiDiscoveryPhase(
	ctx context.Context, job *DiscoveryJob, initialSeeds []string,
) map[string]bool {
	allPotentialSNMPTargets := make(map[string]bool)
	seenMACs := make(map[string]string)

	for _, seedIP := range initialSeeds {
		if seedIP != "" {
			allPotentialSNMPTargets[seedIP] = true
		}
	}

	job.mu.Lock()
	job.Status.Progress = progressInitial / 3
	job.mu.Unlock()

	e.logger.Info().Str("job_id", job.ID).Int("initial_seeds_count", len(initialSeeds)).
		Msg("Phase 1 - UniFi Discovery starting")

	devicesFound := 0
	interfacesFound := 0

	for _, seedIP := range initialSeeds {
		if seedIP == "" {
			continue
		}

		if e.checkPhaseJobCancellation(job, seedIP, "UniFi discovery") {
			return nil
		}

		if len(e.config.UniFiAPIs) > 0 {
			devices, interfaces, err := e.queryUniFiDevices(ctx, job, seedIP)
			if err != nil {
				e.logger.Error().Str("job_id", job.ID).
					Str("seed_ip", seedIP).Err(err).Msg("UniFi discovery for seed failed")

				continue
			}

			devicesFound += len(devices)
			interfacesFound += len(interfaces)

			job.mu.Lock()
			e.processDevicesForSNMPTargets(job, devices, allPotentialSNMPTargets, seenMACs)

			for _, iface := range interfaces {
				if iface.DeviceID == "" && iface.DeviceIP != "" && job.Params.AgentID != "" && job.Params.PollerID != "" {
					iface.DeviceID = fmt.Sprintf("%s:%s:%s",
						job.Params.AgentID, job.Params.PollerID, iface.DeviceIP)
				}

				job.Results.Interfaces = append(job.Results.Interfaces, iface)
			}

			job.mu.Unlock()

			for _, iface := range interfaces {
				if pubErr := e.publisher.PublishInterface(job.ctx, iface); pubErr != nil {
					e.logger.Error().Str("job_id", job.ID).
						Str("device_ip", iface.DeviceIP).
						Err(pubErr).
						Msg("Failed to publish UniFi interface")
				}
			}
		}
	}

	e.logger.Info().Str("job_id", job.ID).Int("devices_found", devicesFound).
		Int("interfaces_found", interfacesFound).Int("snmp_targets", len(allPotentialSNMPTargets)).
		Msg("Phase 1 - UniFi Discovery completed")

	return allPotentialSNMPTargets
}

// processDevicesForSNMPTargets processes devices for SNMP targets with MAC-based deduplication
func (e *DiscoveryEngine) processDevicesForSNMPTargets(
	job *DiscoveryJob, devices []*DiscoveredDevice,
	allPotentialSNMPTargets map[string]bool, seenMACs map[string]string) {
	for _, device := range devices {
		if device.IP != "" {
			e.addOrUpdateDeviceToResults(job, device)

			if device.MAC != "" {
				normalizedMAC := NormalizeMAC(device.MAC)
				if primaryIP, seen := seenMACs[normalizedMAC]; !seen {
					seenMACs[normalizedMAC] = device.IP
					allPotentialSNMPTargets[device.IP] = true

					e.logger.Debug().Str("job_id", job.ID).Str("hostname", device.Hostname).
						Str("mac", device.MAC).Str("ip", device.IP).
						Msg("Adding device to SNMP targets")
				} else {
					e.logger.Debug().Str("job_id", job.ID).Str("hostname", device.Hostname).
						Str("mac", device.MAC).Str("primary_ip", primaryIP).
						Str("skipped_ip", device.IP).
						Msg("Device already in SNMP targets, skipping IP")
				}
			} else {
				allPotentialSNMPTargets[device.IP] = true
			}
		}
	}
}

// setupAndExecuteSNMPPolling sets up and executes the SNMP polling phase
func (e *DiscoveryEngine) setupAndExecuteSNMPPolling(
	job *DiscoveryJob, allPotentialSNMPTargets map[string]bool, initialSeeds []string) bool {
	job.scanQueue = make([]string, 0, len(allPotentialSNMPTargets))

	for ip := range allPotentialSNMPTargets {
		if ip != "" {
			job.scanQueue = append(job.scanQueue, ip)
		}
	}

	totalSNMPTargets := len(job.scanQueue)
	if totalSNMPTargets == 0 {
		e.logger.Info().Str("job_id", job.ID).Strs("seeds", initialSeeds).
			Int("unifi_apis_count", len(e.config.UniFiAPIs)).Msg("No SNMP targets to poll")

		return true
	}

	e.logger.Info().Str("job_id", job.ID).Int("snmp_targets_count", totalSNMPTargets).
		Msg("Phase 2 - SNMP Polling unique target IPs")

	// Setup for SNMP polling
	concurrency := e.determineConcurrency(job, totalSNMPTargets)

	var wgSNMP sync.WaitGroup

	targetChanSNMP := make(chan string, concurrency*defaultConcurrencyMultiplier)
	resultChanSNMP := make(chan bool, totalSNMPTargets)

	// Create a wrapper function that matches the targetProcessorFunc type
	snmpWrapper := func(job *DiscoveryJob, targetIP string) {
		e.scanTargetForSNMP(job.ctx, job, targetIP)
	}

	// Start workers and progress tracking
	e.startWorkers(job, &wgSNMP, targetChanSNMP, resultChanSNMP, concurrency, snmpWrapper)

	baseSNMPProgress := progressInitial / 3
	rangeSNMPProgress := progressScanning - baseSNMPProgress

	go e.trackJobProgress(job, resultChanSNMP, totalSNMPTargets, baseSNMPProgress, rangeSNMPProgress)

	job.mu.Lock()
	job.Status.Progress = baseSNMPProgress
	job.mu.Unlock()

	e.logger.Debug().Str("job_id", job.ID).Strs("scan_queue", job.scanQueue).Msg("Scan queue for SNMP")

	// Execute SNMP polling
	return e.executeSNMPPolling(job, targetChanSNMP, resultChanSNMP, &wgSNMP)
}

// executeSNMPPolling executes the SNMP polling phase
func (e *DiscoveryEngine) executeSNMPPolling(
	job *DiscoveryJob, targetChanSNMP chan<- string, resultChanSNMP chan bool, wgSNMP *sync.WaitGroup) bool {
	if e.feedTargetsToWorkers(job, targetChanSNMP) { // This closes targetChanSNMP
		wgSNMP.Wait()

		close(resultChanSNMP)

		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoverStatusCanceled
			job.Status.Error = "Job canceled during SNMP polling phase"
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()
		e.logger.Info().Str("job_id", job.ID).Msg("SNMP target feeding/processing was canceled")

		return false
	}

	wgSNMP.Wait()

	close(resultChanSNMP)

	// Corrected method name: checkPhaseJobCancellation instead of checkJobCancellation
	return !e.checkPhaseJobCancellation(job, "", "SNMP polling")
}

// trackJobProgress starts a goroutine to track job progress for a specific phase
func (e *DiscoveryEngine) trackJobProgress(
	job *DiscoveryJob,
	resultChan <-chan bool, totalTargets int, baseProgress, progressRange float64) {
	processed := 0
	successful := 0

	for success := range resultChan {
		processed++

		if success {
			successful++
		}

		job.mu.Lock()
		currentProgress := baseProgress

		if totalTargets > 0 {
			currentProgress += (float64(processed) / float64(totalTargets)) * progressRange
		}

		job.Status.Progress = currentProgress
		job.Status.DevicesFound = len(job.Results.Devices)
		job.Status.InterfacesFound = len(job.Results.Interfaces)
		job.Status.TopologyLinks = len(job.Results.TopologyLinks)

		e.logger.Debug().Str("job_id", job.ID).Float64("progress", job.Status.Progress).
			Int("processed", processed).Int("total_targets", totalTargets).
			Int("successful", successful).Int("devices", job.Status.DevicesFound).
			Int("interfaces", job.Status.InterfacesFound).Int("links", job.Status.TopologyLinks).
			Msg("Job progress update")

		job.mu.Unlock()

		select {
		case <-job.ctx.Done():
			e.logger.Debug().Str("job_id", job.ID).Msg("Progress tracking stopping due to cancellation")
			return
		case <-e.done:
			e.logger.Debug().Str("job_id", job.ID).Msg("Progress tracking stopping due to engine shutdown")
			return
		default:
		}
	}

	e.logger.Debug().Str("job_id", job.ID).Int("successful", successful).
		Int("total_targets", totalTargets).Msg("Progress tracking finished for this phase")
}

// finalizeDevice performs final setup on the device before returning it
func (*DiscoveryEngine) finalizeDevice(device *DiscoveredDevice, target, jobID, source string) {
	// Use IP as hostname if not provided
	if device.Hostname == "" {
		device.Hostname = target
	}

	// Add job metadata
	device.Metadata["discovery_id"] = jobID
	device.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
	device.Metadata["source"] = source
}

// finalizeInterfaces finalizes the interfaces by ensuring they have names and adding metadata
func (*DiscoveryEngine) finalizeInterfaces(
	job *DiscoveryJob, ifMap map[int]*DiscoveredInterface, jobID string) []*DiscoveredInterface {
	interfaces := make([]*DiscoveredInterface, 0, len(ifMap))

	// Cache devices by IP for lookup
	job.mu.RLock()
	deviceMap := make(map[string]*DiscoveredDevice)

	for _, device := range job.Results.Devices {
		deviceMap[device.IP] = device
	}

	job.mu.RUnlock()

	for _, iface := range ifMap {
		if iface.IfName == "" {
			if iface.IfDescr != "" {
				iface.IfName = iface.IfDescr
			} else {
				iface.IfName = fmt.Sprintf("Interface-%d", iface.IfIndex)
			}
		}

		iface.Metadata["discovery_id"] = jobID
		iface.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)

		interfaces = append(interfaces, iface)
	}

	return interfaces
}
