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

package discovery

import "errors"

var (
	ErrDiscoveryStopTimeout     = errors.New("discovery engine stop timed out")
	ErrDiscoveryAtCapacity      = errors.New("discovery engine at capacity, please try again later")
	ErrDiscoveryShuttingDown    = errors.New("discovery engine is shutting down")
	ErrDiscoveryWorkersBusy     = errors.New("discovery engine at capacity (workers busy), please try again later")
	ErrDiscoveryJobNotFound     = errors.New("discovery job not found")
	ErrDiscoveryJobStillActive  = errors.New("discovery job is still active")
	ErrDiscoveryJobNotCompleted = errors.New("discovery job not found or not completed")
	ErrDiscoveryJobNotActive    = errors.New("discovery job not found or not active")
	ErrConfigNil                = errors.New("config cannot be nil")
	ErrInvalidWorkers           = errors.New("workers must be greater than 0")
	ErrInvalidMaxActiveJobs     = errors.New("maxActiveJobs must be greater than 0")
	ErrUnsupportedSNMPVersion   = errors.New("unsupported SNMP version")
)
