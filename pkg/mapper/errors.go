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

import "errors"

var (
	// ErrDiscoveryStopTimeout occurs when the discovery engine fails to stop within the timeout period.
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

	ErrDatabaseServiceRequired = errors.New("database service is required")
	ErrDeviceRegistryRequired  = errors.New("device registry is required")
	ErrSNMPGetFailed           = errors.New("SNMP GET failed")
	ErrSNMPError               = errors.New("SNMP error occurred")
	ErrNoSNMPDataReturned      = errors.New("no SNMP data returned")
	ErrNoLLDPNeighborsFound    = errors.New("no LLDP neighbors found")
	ErrNoCDPNeighborsFound     = errors.New("no CDP neighbors found")
	ErrNoICMPResponse          = errors.New("no ICMP response")
	ErrInt32RangeExceeded      = errors.New("value exceeds int32 range")
	ErrFoundMACStoppingWalk    = errors.New("found MAC, stopping walk")
	ErrConnectionTimeout       = errors.New("connection timeout")
	
	// UniFi/UBNT specific errors
	ErrUniFiSitesRequestFailed  = errors.New("UniFi sites request failed")
	ErrNoUniFiSitesFound        = errors.New("no UniFi sites found")
	ErrUniFiDevicesRequestFailed = errors.New("UniFi devices request failed")
	ErrUniFiDeviceDetailsFailed = errors.New("UniFi device details request failed")
	ErrNoUniFiDevicesFound      = errors.New("no UniFi devices found; all API attempts failed")
	ErrSNMPQueryTimeout         = errors.New("SNMP query timeout")

	// ErrNoSeedsProvided occurs when no discovery seeds are provided for a job.
	ErrNoSeedsProvided         = errors.New("no seeds provided")
	ErrJobQueueFull            = errors.New("job queue full, cannot enqueue discovery job")
	ErrScheduledJobMissingName = errors.New("scheduled job missing name")
	ErrJobHasNoSeeds           = errors.New("job has no seeds")
	ErrJobMissingType          = errors.New("job missing type")
	ErrJobInvalidType          = errors.New("job has invalid type")
	ErrJobInvalidConcurrency   = errors.New("job has invalid concurrency")
	ErrJobInvalidRetries       = errors.New("job has invalid retries")
)
