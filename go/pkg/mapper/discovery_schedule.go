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
	"strings"
	"time"
)

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

		params, err := e.buildDiscoveryParamsForJob(jobConfig)
		if err != nil {
			e.logger.Error().Str("job", jobConfig.Name).Err(err).
				Msg("Invalid job configuration, skipping")
			continue
		}

		// Start the job immediately
		_, _ = e.startScheduledJob(ctx, jobConfig.Name, params)

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
					_, _ = e.startScheduledJob(ctx, name, params)
				}
			}
		}(jobConfig.Name, params)
	}

	e.logger.Info().Msg("All scheduled jobs initialized")
}

// RunScheduledJob triggers a named scheduled job immediately.
func (e *DiscoveryEngine) RunScheduledJob(ctx context.Context, name string) (string, error) {
	var jobConfig *ScheduledJob

	e.mu.RLock()
	for i := range e.config.ScheduledJobs {
		if e.config.ScheduledJobs[i].Name == name {
			jobConfig = e.config.ScheduledJobs[i]
			break
		}
	}
	e.mu.RUnlock()

	if jobConfig == nil {
		return "", ErrScheduledJobNotFound
	}

	params, err := e.buildDiscoveryParamsForJob(jobConfig)
	if err != nil {
		return "", err
	}

	return e.startScheduledJob(ctx, jobConfig.Name, params)
}

// RunScheduledJobWithSeeds triggers a named scheduled job immediately with an override seed set.
func (e *DiscoveryEngine) RunScheduledJobWithSeeds(ctx context.Context, name string, seeds []string) (string, error) {
	var jobConfig *ScheduledJob

	e.mu.RLock()
	for i := range e.config.ScheduledJobs {
		if e.config.ScheduledJobs[i].Name == name {
			jobConfig = e.config.ScheduledJobs[i]
			break
		}
	}
	e.mu.RUnlock()

	if jobConfig == nil {
		return "", ErrScheduledJobNotFound
	}

	params, err := e.buildDiscoveryParamsForJob(jobConfig)
	if err != nil {
		return "", err
	}

	overrideSeeds := normalizeOverrideSeeds(seeds)
	if len(overrideSeeds) > 0 {
		params.Seeds = overrideSeeds
	}

	return e.startScheduledJob(ctx, jobConfig.Name, params)
}

func (e *DiscoveryEngine) buildDiscoveryParamsForJob(jobConfig *ScheduledJob) (*DiscoveryParams, error) {
	if jobConfig == nil {
		return nil, ErrConfigNil
	}

	timeout := e.config.Timeout
	if jobConfig.Timeout != "" {
		parsed, err := time.ParseDuration(jobConfig.Timeout)
		if err != nil {
			e.logger.Warn().Str("job", jobConfig.Name).Err(err).
				Msg("Invalid timeout for job, using default config timeout")
		} else {
			timeout = parsed
		}
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
		return nil, ErrJobInvalidType
	}

	params := &DiscoveryParams{
		Seeds:       jobConfig.Seeds,
		Type:        discoveryType,
		Mode:        resolveDiscoveryMode(jobConfig),
		Credentials: &(jobConfig.Credentials),
		Options:     jobConfig.Options,
		Concurrency: jobConfig.Concurrency,
		Timeout:     timeout,
		Retries:     jobConfig.Retries,
		AgentID:     e.config.StreamConfig.AgentID,
		GatewayID:   e.config.StreamConfig.GatewayID,
	}

	return params, nil
}

func resolveDiscoveryMode(jobConfig *ScheduledJob) string {
	if jobConfig == nil {
		return ""
	}

	mode := strings.TrimSpace(strings.ToLower(jobConfig.DiscoveryMode))
	if mode != "" {
		return mode
	}

	if jobConfig.Options == nil {
		return ""
	}

	if mode = strings.TrimSpace(strings.ToLower(jobConfig.Options["discovery_mode"])); mode != "" {
		return mode
	}
	if mode = strings.TrimSpace(strings.ToLower(jobConfig.Options["mode"])); mode != "" {
		return mode
	}
	if strings.EqualFold(strings.TrimSpace(jobConfig.Options["snmp_only"]), "true") {
		return discoveryModeSNMP
	}

	return ""
}

func normalizeOverrideSeeds(seeds []string) []string {
	if len(seeds) == 0 {
		return nil
	}

	normalized := make([]string, 0, len(seeds))
	seen := make(map[string]struct{}, len(seeds))
	for _, seed := range seeds {
		seed = strings.TrimSpace(seed)
		if seed == "" {
			continue
		}
		if _, ok := seen[seed]; ok {
			continue
		}
		seen[seed] = struct{}{}
		normalized = append(normalized, seed)
	}

	return normalized
}

// startScheduledJob initiates a discovery job.
func (e *DiscoveryEngine) startScheduledJob(ctx context.Context, name string, params *DiscoveryParams) (string, error) {
	e.logger.Info().Str("job", name).Msg("Starting scheduled job")

	discoveryID, err := e.StartDiscovery(ctx, params)
	if err != nil {
		e.logger.Error().Str("job", name).Err(err).Msg("Failed to start scheduled job")
		return "", err
	}

	// Add job name to job metadata
	e.mu.RLock()

	if job, exists := e.activeJobs[discoveryID]; exists {
		job.Results.Contract.ScheduledJobName = name
		job.Results.Contract.AgentID = params.AgentID
		job.Results.Contract.GatewayID = params.GatewayID
	}

	e.mu.RUnlock()

	e.logger.Info().Str("job", name).Str("discovery_id", discoveryID).
		Msg("Scheduled job started with discovery ID")

	return discoveryID, nil
}

// StartDiscovery initiates a discovery operation with the given parameters.
