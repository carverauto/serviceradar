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
	"fmt"
	"time"
)

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
		return fmt.Errorf("%w", ErrScheduledJobMissingName)
	}

	if !job.Enabled {
		return nil
	}

	if _, err := time.ParseDuration(job.Interval); err != nil {
		return fmt.Errorf("invalid interval for job %s: %w", job.Name, err)
	}

	if len(job.Seeds) == 0 {
		return fmt.Errorf("job %s: %w", job.Name, ErrJobHasNoSeeds)
	}

	if job.Type == "" {
		return fmt.Errorf("job %s: %w", job.Name, ErrJobMissingType)
	}

	// Validate that job.Type is one of the valid DiscoveryType values
	validTypes := map[string]bool{
		string(DiscoveryTypeFull):       true,
		string(DiscoveryTypeBasic):      true,
		string(DiscoveryTypeInterfaces): true,
		string(DiscoveryTypeTopology):   true,
	}
	if !validTypes[job.Type] {
		return fmt.Errorf("job %s has invalid type %s: %w", job.Name, job.Type, ErrJobInvalidType)
	}

	if job.Concurrency < 0 {
		return fmt.Errorf("job %s has invalid concurrency %d: %w", job.Name, job.Concurrency, ErrJobInvalidConcurrency)
	}

	if job.Retries < 0 {
		return fmt.Errorf("job %s has invalid retries %d: %w", job.Name, job.Retries, ErrJobInvalidRetries)
	}

	if job.Timeout != "" {
		if _, err := time.ParseDuration(job.Timeout); err != nil {
			return fmt.Errorf("invalid timeout for job %s: %w", job.Name, err)
		}
	}

	return nil
}
