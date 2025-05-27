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
	"log"
	"sync"
	"time"

	"github.com/google/uuid"
)

// NewDiscoveryEngine creates a new discovery engine with the given configuration
func NewDiscoveryEngine(config *Config, publisher Publisher) (Mapper, error) {
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
		// mu is initialized by default (zero value is usable)
	}

	return engine, nil
}

// Start initializes and starts the discovery engine
func (e *DiscoveryEngine) Start(ctx context.Context) error {
	log.Printf("Starting DiscoveryEngine with %d workers and %d max active jobs...",
		e.workers, e.config.MaxActiveJobs)

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

	log.Println("DiscoveryEngine started.")

	return nil
}

const (
	defaultFallbackTimeout = 10 * time.Second // Fallback timeout for stopping
)

// Stop gracefully shuts down the discovery engine
func (e *DiscoveryEngine) Stop(ctx context.Context) error {
	log.Println("Stopping DiscoveryEngine...")

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
		log.Println("All DiscoveryEngine goroutines stopped.")
	case <-ctx.Done():
		log.Printf("DiscoveryEngine stop timed out or context canceled: %v", ctx.Err())
		return ctx.Err()
	case <-time.After(defaultFallbackTimeout): // Fallback timeout
		log.Println("DiscoveryEngine stop timed out after 10s.")
		return ErrDiscoveryStopTimeout
	}

	// Close jobChan after workers have stopped to prevent sending to closed channel
	close(e.jobChan)

	log.Println("DiscoveryEngine stopped.")

	return nil
}

// StartDiscovery initiates a discovery operation with the given parameters.
func (e *DiscoveryEngine) StartDiscovery(ctx context.Context, params *DiscoveryParams) (string, error) {
	e.mu.Lock()
	// Intentionally not using defer e.mu.Unlock() here because of the select block
	// that might block. We will unlock manually before returning or if an error occurs early.

	discoveryID := uuid.New().String()

	// Create a new context for this specific job, derived from the incoming context.
	// This allows the job to be canceled independently or if the parent ctx is canceled.
	jobSpecificCtx, cancelFunc := context.WithCancel(context.Background())

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

		return "", ErrDiscoveryAtCapacity
	}

	// Try to send to jobChan (secondary gate, indicates worker availability)
	select {
	case e.jobChan <- job:
		// Job submitted successfully
		e.activeJobs[discoveryID] = job // Add to active jobs *after* successfully sending to channel
		e.mu.Unlock()                   // Unlock after all shared state modification

		log.Printf("Discovery job %s submitted with %d seeds.", discoveryID, len(params.Seeds))

		return discoveryID, nil
	case <-ctx.Done(): // Incoming request context canceled
		e.mu.Unlock()
		cancelFunc() // Clean up the job-specific context

		log.Printf("Job %s submission canceled because parent context was done: %v", discoveryID, ctx.Err())

		return "", ctx.Err()
	case <-e.done: // Engine is shutting down
		e.mu.Unlock()
		cancelFunc() // Clean up the job-specific context

		log.Printf("Job %s submission failed because engine is shutting down.", discoveryID)

		return "", ErrDiscoveryShuttingDown
	default: // jobChan is full, workers are at capacity
		e.mu.Unlock()
		cancelFunc() // Clean up the job-specific context

		log.Printf("Discovery engine at capacity (jobChan full), job %s rejected.", discoveryID)

		return "", ErrDiscoveryWorkersBusy
	}
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

	log.Printf("Discovery job %s canceled.", discoveryID)

	return nil
}

// worker processes discovery jobs from jobChan
func (e *DiscoveryEngine) worker(ctx context.Context, workerID int) {
	defer e.wg.Done()

	log.Printf("Discovery worker %d started.", workerID)

	for {
		select {
		case <-ctx.Done(): // Main context canceled
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
			log.Printf("Worker %d finished job %s with status %s.", workerID, job.ID, job.Status.Status)
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

		log.Printf("Discovery config: Timeout not set or invalid, defaulting to %v", config.Timeout)
	}

	if config.ResultRetention <= 0 {
		config.ResultRetention = defaultResultRetention

		log.Printf("Discovery config: ResultRetention not set or invalid, defaulting to %v",
			config.ResultRetention)
	}

	// Further checks for OIDs, StreamConfig etc. can be added here
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
				log.Printf("Job %s: Failed to publish %s link %s/%d: %v",
					job.ID, protocol, target, link.LocalIfIndex, err)
			}
		}
	}
}

// handleEmptyTargetList updates job status when no valid targets are found
func (*DiscoveryEngine) handleEmptyTargetList(job *DiscoveryJob) {
	job.mu.Lock()
	job.Status.Status = DiscoveryStatusFailed
	job.Status.Error = "No valid targets to scan after processing seeds"
	job.Status.Progress = 100
	job.mu.Unlock()

	log.Printf("Job %s: Failed - no valid targets to scan", job.ID)
}

// determineConcurrency calculates the appropriate concurrency level.
func (*DiscoveryEngine) determineConcurrency(job *DiscoveryJob, totalTargets int) int {
	concurrency := job.Params.Concurrency

	if concurrency <= 0 {
		concurrency = defaultConcurrency
	}

	if concurrency > totalTargets {
		concurrency = totalTargets // Don't create more workers than needed
	}

	return concurrency
}

type targetProcessorFunc func(job *DiscoveryJob, targetIP, agentID, pollerID string)

// startWorkers launches worker goroutines to process targets using the provided processor function.
func (e *DiscoveryEngine) startWorkers(
	job *DiscoveryJob,
	wg *sync.WaitGroup,
	targetChan <-chan string,
	resultChan chan<- bool,
	concurrency int,
	processor targetProcessorFunc, // Function to process each target
) {
	for i := 0; i < concurrency; i++ {
		wg.Add(1)

		go func(workerID int) {
			defer wg.Done()

			for target := range targetChan {
				select {
				case <-job.ctx.Done():
					log.Printf("Job %s: Worker %d (target: %s) stopping due to cancellation",
						job.ID, workerID, target)
					resultChan <- false // Signal non-completion

					return
				case <-e.done:
					log.Printf("Job %s: Worker %d (target: %s) stopping due to engine shutdown",
						job.ID, workerID, target)
					resultChan <- false // Signal non-completion

					return
				default:
					// Ping host before processing
					if pingErr := pingHost(job.ctx, target); pingErr != nil {
						log.Printf("Job %s: Host %s is not responding to ICMP ping by worker %d: %v",
							job.ID, target, workerID, pingErr)
						resultChan <- false // Signal failure for this target

						continue // Allow worker to process next target
					}

					// Process target using the provided processor function
					processor(job, target, job.Params.AgentID, job.Params.PollerID)
					resultChan <- true // Signal completion for progress tracking
				}
			}

			log.Printf("Job %s: Worker %d finished processing targets.", job.ID, workerID)
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
			log.Printf("Job %s: Stopping target feed due to cancellation", job.ID)
			close(targetChan)

			return true
		case <-e.done:
			log.Printf("Job %s: Stopping target feed due to engine shutdown", job.ID)
			close(targetChan)

			return true
		}
	}

	close(targetChan)

	return false
}

// checkJobCancellation checks if the job was canceled or the engine is shutting down
// Returns true if the job was canceled
func (e *DiscoveryEngine) checkJobCancellation(job *DiscoveryJob) bool {
	select {
	case <-job.ctx.Done():
		job.mu.Lock()
		job.Status.Status = DiscoverStatusCanceled
		job.Status.Error = "Job canceled during execution"
		job.mu.Unlock()

		log.Printf("Job %s: Canceled during execution", job.ID)

		return true
	case <-e.done:
		job.mu.Lock()
		job.Status.Status = DiscoveryStatusFailed
		job.Status.Error = "Engine shutting down"
		job.mu.Unlock()

		log.Printf("Job %s: Failed due to engine shutdown", job.ID)

		return true
	default:
		// Job completed successfully
		return false
	}
}

// finalizeJobStatus updates the job status after completion
func (*DiscoveryEngine) finalizeJobStatus(job *DiscoveryJob) {
	job.mu.Lock()
	if job.Status.Status == DiscoveryStatusRunning {
		job.Status.Status = DiscoveryStatusCompleted
		job.Status.Progress = progressCompleted

		if len(job.Results.Devices) == 0 {
			job.Status.Error = "No SNMP devices found"
			log.Printf("Job %s: Completed - no SNMP devices found", job.ID)
		} else {
			log.Printf("Job %s: Completed successfully. Found %d devices, %d interfaces, %d topology links",
				job.ID, len(job.Results.Devices), len(job.Results.Interfaces), len(job.Results.TopologyLinks))
		}
	}
	job.mu.Unlock()
}

const (
	defaultConcurrencyMultiplier = 2 // Multiplier for target channel size
)

// addOrUpdateDeviceToResults adds or updates a device in the job's results.
// It assumes job.mu is already locked if called from a context where it's needed.
func (e *DiscoveryEngine) addOrUpdateDeviceToResults(job *DiscoveryJob, newDevice *DiscoveredDevice) {
	e.ensureDeviceID(job, newDevice)

	// Try to find and update an existing device
	for i, existingDevice := range job.Results.Devices {
		if e.isDeviceMatch(existingDevice, newDevice) {
			e.updateExistingDevice(job, i, newDevice)
			return
		}
	}

	// Not found, append as a new device
	e.addNewDevice(job, newDevice)
}

// ensureDeviceID ensures the DeviceID is populated if possible
func (*DiscoveryEngine) ensureDeviceID(job *DiscoveryJob, device *DiscoveredDevice) {
	if device.DeviceID == "" && device.IP != "" && job.Params.AgentID != "" && job.Params.PollerID != "" {
		device.DeviceID = fmt.Sprintf("%s:%s:%s", job.Params.AgentID, job.Params.PollerID, device.IP)
	}
}

// isDeviceMatch checks if two devices match based on DeviceID or IP
func (*DiscoveryEngine) isDeviceMatch(existingDevice, newDevice *DiscoveredDevice) bool {
	if newDevice.DeviceID != "" && existingDevice.DeviceID == newDevice.DeviceID {
		return true
	}

	if existingDevice.IP == newDevice.IP { // Fallback to IP match
		return true
	}

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
			log.Printf("Job %s: Failed to publish device %s: %v", job.ID, device.IP, err)
		}
	}
}

// runDiscoveryJob performs the actual discovery for a job, now in two phases.
func (e *DiscoveryEngine) runDiscoveryJob(ctx context.Context, job *DiscoveryJob) {
	log.Printf("Running discovery for job %s. Seeds: %v, Type: %s", job.ID, job.Params.Seeds, job.Params.Type)

	initialSeeds := expandSeeds(job.Params.Seeds)
	if len(initialSeeds) == 0 {
		e.handleEmptyTargetList(job)
		return
	}

	// Phase 1: UniFi Device Discovery
	allPotentialSNMPTargets := e.handleUniFiDiscoveryPhase(ctx, job, initialSeeds)

	// Phase 2: SNMP Polling
	if !e.setupAndExecuteSNMPPolling(job, allPotentialSNMPTargets, initialSeeds) {
		return
	}

	e.finalizeJobStatus(job)
}

// handleUniFiDiscoveryPhase performs the UniFi discovery phase and collects potential SNMP targets
func (e *DiscoveryEngine) handleUniFiDiscoveryPhase(
	ctx context.Context, job *DiscoveryJob, initialSeeds []string) map[string]bool {
	allPotentialSNMPTargets := make(map[string]bool)

	for _, seedIP := range initialSeeds {
		if seedIP != "" { // Ensure seedIP is valid before adding
			allPotentialSNMPTargets[seedIP] = true
		}
	}

	job.mu.Lock()
	job.Status.Progress = progressInitial / 3
	job.mu.Unlock()

	log.Printf("Job %s: Phase 1 - UniFi Discovery starting with %d initial seeds.", job.ID, len(initialSeeds))

	for _, seedIP := range initialSeeds {
		if seedIP == "" { // Skip empty seed IPs that might have resulted from expansion
			continue
		}

		if e.checkPhaseJobCancellation(job, seedIP, "UniFi discovery") {
			return nil
		}

		if len(e.config.UniFiAPIs) > 0 {
			e.processUniFiSeed(ctx, job, seedIP, allPotentialSNMPTargets)
		}
	}

	log.Printf("Job %s: Phase 1 - UniFi Discovery completed. Found %d potential SNMP targets.",
		job.ID, len(allPotentialSNMPTargets))

	return allPotentialSNMPTargets
}

// checkPhaseJobCancellation checks if the job has been canceled or the engine is shutting down
func (e *DiscoveryEngine) checkPhaseJobCancellation(job *DiscoveryJob, seedIP, phaseName string) bool {
	select {
	case <-job.ctx.Done():
		log.Printf("Job %s: %s phase canceled for seed %s.", job.ID, phaseName, seedIP)

		job.mu.Lock()

		if job.Status.Status != DiscoverStatusCanceled && job.Status.Status != DiscoveryStatusFailed {
			job.Status.Status = DiscoverStatusCanceled
			job.Status.Error = fmt.Sprintf("Job canceled during %s phase", phaseName)
			job.Status.EndTime = time.Now()
		}

		job.mu.Unlock()

		return true
	case <-e.done:
		log.Printf("Job %s: %s phase stopped due to engine shutdown for seed %s.", job.ID, phaseName, seedIP)
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

// processUniFiSeed processes a single seed IP for UniFi discovery
func (e *DiscoveryEngine) processUniFiSeed(
	ctx context.Context, job *DiscoveryJob, seedIP string, allPotentialSNMPTargets map[string]bool) {
	devicesFromUniFi, interfacesFromUniFi, err :=
		e.queryUniFiDevices(ctx, job, seedIP, job.Params.AgentID, job.Params.PollerID)
	if err == nil {
		job.mu.Lock()

		for _, device := range devicesFromUniFi {
			if device.IP != "" { // Only add devices with valid IPs
				e.addOrUpdateDeviceToResults(job, device)

				allPotentialSNMPTargets[device.IP] = true
			}
		}

		for _, iface := range interfacesFromUniFi {
			if iface.DeviceID == "" && iface.DeviceIP != "" && job.Params.AgentID != "" && job.Params.PollerID != "" {
				iface.DeviceID = fmt.Sprintf("%s:%s:%s",
					job.Params.AgentID, job.Params.PollerID, iface.DeviceIP)
			}

			job.Results.Interfaces = append(job.Results.Interfaces, iface)
		}

		job.mu.Unlock()

		for _, iface := range interfacesFromUniFi {
			if pubErr := e.publisher.PublishInterface(job.ctx, iface); pubErr != nil {
				log.Printf("Job %s: Failed to publish UniFi interface for %s: %v",
					job.ID, iface.DeviceIP, pubErr)
			}
		}
	} else {
		log.Printf("Job %s: Failed to query UniFi devices using seed %s: %v", job.ID, seedIP, err)
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
		log.Printf("Job %s: No SNMP targets to poll (seeds: %v, UniFiAPIs count: %d).",
			job.ID, initialSeeds, len(e.config.UniFiAPIs))
		return true
	}

	log.Printf("Job %s: Phase 2 - SNMP Polling %d unique target IPs.", job.ID, totalSNMPTargets)

	// Setup for SNMP polling
	concurrency := e.determineConcurrency(job, totalSNMPTargets)

	var wgSNMP sync.WaitGroup

	targetChanSNMP := make(chan string, concurrency*defaultConcurrencyMultiplier)
	resultChanSNMP := make(chan bool, totalSNMPTargets)

	// Create a wrapper function that matches the targetProcessorFunc type
	snmpWrapper := func(job *DiscoveryJob, targetIP, agentID, pollerID string) {
		e.scanTargetForSNMP(job.ctx, job, targetIP, agentID, pollerID)
	}

	// Start workers and progress tracking
	e.startWorkers(job, &wgSNMP, targetChanSNMP, resultChanSNMP, concurrency, snmpWrapper)

	baseSNMPProgress := progressInitial / 3
	rangeSNMPProgress := progressScanning - baseSNMPProgress

	go e.trackJobProgress(job, resultChanSNMP, totalSNMPTargets, baseSNMPProgress, rangeSNMPProgress)

	job.mu.Lock()
	job.Status.Progress = baseSNMPProgress
	job.mu.Unlock()

	log.Printf("Job %s: Scan queue for SNMP: %v", job.ID, job.scanQueue)

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
		log.Printf("Job %s: SNMP target feeding/processing was canceled.", job.ID)

		return false
	}

	wgSNMP.Wait()
	close(resultChanSNMP)

	return !e.checkJobCancellation(job)
}

// scanTargetForSNMP performs SNMP-specific discovery for a single target.
func (e *DiscoveryEngine) scanTargetForSNMP(
	ctx context.Context, job *DiscoveryJob, snmpTargetIP, agentID, pollerID string) {
	log.Printf("Job %s: SNMP Scanning target %s", job.ID, snmpTargetIP)

	if len(e.config.UniFiAPIs) > 0 && (job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeTopology) {
		links, err := e.queryUniFiAPI(ctx, job, snmpTargetIP, agentID, pollerID)
		if err == nil && len(links) > 0 {
			e.publishTopologyLinks(job, links, snmpTargetIP, "UniFi-API")
		}
	}

	client, err := e.setupSNMPClient(job, snmpTargetIP)
	if err != nil {
		log.Printf("Job %s: Failed to setup SNMP client for %s: %v", job.ID, snmpTargetIP, err)
		return
	}

	defer func() {
		if cErr := client.Conn.Close(); cErr != nil {
			log.Printf("Job %s: Error closing SNMP connection for %s: %v", job.ID, snmpTargetIP, cErr)
		}
	}()

	deviceSNMP, err := e.querySysInfo(client, snmpTargetIP, job.ID)
	if err != nil {
		log.Printf("Job %s: Failed to query system info via SNMP for %s: %v", job.ID, snmpTargetIP, err)
		return
	}

	job.mu.Lock()
	e.addOrUpdateDeviceToResults(job, deviceSNMP) // Handles publishing internally
	job.mu.Unlock()

	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeInterfaces {
		e.handleInterfaceDiscoverySNMP(job, client, snmpTargetIP, agentID, pollerID)
	}

	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == DiscoveryTypeTopology {
		e.handleTopologyDiscoverySNMP(job, client, snmpTargetIP, agentID, pollerID)
	}
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

		log.Printf("Job %s: Progress %.2f%% (%d/%d processed, %d successful). Devices: %d, Interfaces: %d, Links: %d",
			job.ID, job.Status.Progress, processed, totalTargets, successful,
			job.Status.DevicesFound, job.Status.InterfacesFound, job.Status.TopologyLinks)

		job.mu.Unlock()

		select {
		case <-job.ctx.Done():
			log.Printf("Job %s: Progress tracking stopping due to cancellation", job.ID)
			return
		case <-e.done:
			log.Printf("Job %s: Progress tracking stopping due to engine shutdown", job.ID)
			return
		default:
		}
	}

	log.Printf("Job %s: Progress tracking finished for this phase. %d/%d targets successfully processed.", job.ID, successful, totalTargets)
}

// finalizeDevice performs final setup on the device before returning it
func (*DiscoveryEngine) finalizeDevice(device *DiscoveredDevice, target, jobID string) {
	// Use IP as hostname if not provided
	if device.Hostname == "" {
		device.Hostname = target
	}

	// Add job metadata
	device.Metadata["discovery_id"] = jobID
	device.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
}

// finalizeInterfaces finalizes the interfaces by ensuring they have names and adding metadata
func (*DiscoveryEngine) finalizeInterfaces(
	job *DiscoveryJob, ifMap map[int]*DiscoveredInterface, jobID string, agentID string, pollerID string) []*DiscoveredInterface {
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

		if iface.DeviceID == "" && iface.DeviceIP != "" {
			if device, exists := deviceMap[iface.DeviceIP]; exists && device.DeviceID != "" {
				iface.DeviceID = device.DeviceID
			} else if agentID != "" && pollerID != "" {
				iface.DeviceID = fmt.Sprintf("%s:%s:%s", iface.DeviceIP, agentID, pollerID)
			} else {
				iface.DeviceID = iface.DeviceIP
				log.Printf("Job %s: Missing agentID or pollerID for interface on %s, using IP as DeviceID",
					jobID, iface.DeviceIP)
			}
		}

		iface.Metadata["discovery_id"] = jobID
		iface.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)

		interfaces = append(interfaces, iface)
	}

	return interfaces
}
