package mapper

import (
	"context"
	"log"
	"time"
)

// StartScheduledJobs starts all configured scheduled discovery jobs.
func (e *DiscoveryEngine) StartScheduledJobs(ctx context.Context) error {
	if len(e.config.ScheduledJobs) == 0 {
		log.Println("No scheduled discovery jobs configured")
		return nil
	}

	e.mu.Lock()

	if e.scheduledJobs == nil {
		e.scheduledJobs = make(map[string]*ScheduledJob)
	}

	e.mu.Unlock()

	for _, jobConfig := range e.config.ScheduledJobs {
		if !jobConfig.Enabled {
			log.Printf("Scheduled job %s is disabled, skipping", jobConfig.Name)
			continue
		}

		interval, err := time.ParseDuration(jobConfig.Interval)
		if err != nil {
			log.Printf("Invalid interval for job %s: %v", jobConfig.Name, err)
			continue
		}

		timeout, _ := time.ParseDuration(jobConfig.Timeout)
		if timeout == 0 {
			timeout = e.config.Timeout
		}

		// Convert job config to discovery params
		params := &DiscoveryParams{
			Seeds:       jobConfig.Seeds,
			Type:        stringToDiscoveryType(jobConfig.Type),
			Credentials: &jobConfig.Credentials,
			Concurrency: jobConfig.Concurrency,
			Timeout:     timeout,
			Retries:     jobConfig.Retries,
			AgentID:     e.config.StreamConfig.AgentID,
			PollerID:    e.config.StreamConfig.PollerID,
		}

		job := &ScheduledJob{
			Name:     jobConfig.Name,
			Interval: interval,
			Enabled:  true,
			Params:   params,
			stopChan: make(chan struct{}),
		}

		// Start the job goroutine
		e.wg.Add(1)
		go e.runScheduledJob(ctx, job)

		e.mu.Lock()
		e.scheduledJobs[jobConfig.Name] = job
		e.mu.Unlock()

		log.Printf("Started scheduled discovery job '%s' with interval %v", job.Name, job.Interval)
	}

	return nil
}

// runScheduledJob runs a single scheduled discovery job
func (e *DiscoveryEngine) runScheduledJob(ctx context.Context, job *ScheduledJob) {
	defer e.wg.Done()

	// Run immediately on start
	e.executeScheduledDiscovery(ctx, job)

	// Create ticker for periodic execution
	ticker := time.NewTicker(job.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("Scheduled job %s stopping due to context cancellation", job.Name)
			return
		case <-e.done:
			log.Printf("Scheduled job %s stopping due to engine shutdown", job.Name)
			return
		case <-job.stopChan:
			log.Printf("Scheduled job %s stopped", job.Name)
			return
		case <-ticker.C:
			e.executeScheduledDiscovery(ctx, job)
		}
	}
}

// executeScheduledDiscovery executes a scheduled discovery
func (e *DiscoveryEngine) executeScheduledDiscovery(ctx context.Context, job *ScheduledJob) {
	log.Printf("Executing scheduled discovery job '%s'", job.Name)

	job.LastRun = time.Now()
	job.NextRun = job.LastRun.Add(job.Interval)

	// Check if we're at capacity
	e.mu.RLock()
	activeCount := len(e.activeJobs)
	e.mu.RUnlock()

	if activeCount >= e.config.MaxActiveJobs {
		log.Printf("Skipping scheduled job %s: at capacity (%d/%d active jobs)",
			job.Name, activeCount, e.config.MaxActiveJobs)
		return
	}

	// Start the discovery
	discoveryID, err := e.StartDiscovery(ctx, job.Params)
	if err != nil {
		log.Printf("Failed to start scheduled discovery '%s': %v", job.Name, err)
		return
	}

	job.LastJobID = discoveryID

	log.Printf("Started scheduled discovery '%s' with ID %s, next run at %v",
		job.Name, discoveryID, job.NextRun.Format(time.RFC3339))
}

// StopScheduledJobs stops all scheduled discovery jobs
func (e *DiscoveryEngine) StopScheduledJobs() {
	e.mu.Lock()
	defer e.mu.Unlock()

	for name, job := range e.scheduledJobs {
		close(job.stopChan)
		log.Printf("Stopped scheduled job %s", name)
	}

	e.scheduledJobs = make(map[string]*ScheduledJob)
}

// GetScheduledJobStatus returns the status of scheduled jobs
func (e *DiscoveryEngine) GetScheduledJobStatus() []ScheduledJobStatus {
	e.mu.RLock()
	defer e.mu.RUnlock()

	statuses := make([]ScheduledJobStatus, 0, len(e.scheduledJobs))

	for _, job := range e.scheduledJobs {
		status := ScheduledJobStatus{
			Name:      job.Name,
			Enabled:   job.Enabled,
			Interval:  job.Interval.String(),
			LastRun:   job.LastRun,
			NextRun:   job.NextRun,
			LastJobID: job.LastJobID,
		}
		statuses = append(statuses, status)
	}

	return statuses
}

func stringToDiscoveryType(s string) DiscoveryType {
	switch s {
	case "full":
		return DiscoveryTypeFull
	case "basic":
		return DiscoveryTypeBasic
	case "interfaces":
		return DiscoveryTypeInterfaces
	case "topology":
		return DiscoveryTypeTopology
	default:
		return DiscoveryTypeFull
	}
}
