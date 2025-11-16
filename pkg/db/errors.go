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

package db

import "errors"

var (

	// Core database errors.

	ErrDatabaseError = errors.New("database error")

	// Operation errors.

	ErrFailedToScan   = errors.New("failed to scan")
	ErrFailedToQuery  = errors.New("failed to query")
	ErrFailedToInsert = errors.New("failed to insert")
	ErrFailedToInit   = errors.New("failed to initialize schema")
	ErrFailedOpenDB   = errors.New("failed to open database")

	// Auth.

	ErrUserNotFound = errors.New("user not found")

	// Edge onboarding.

	ErrEdgePackageNotFound = errors.New("edge onboarding package not found")
	ErrEdgePackageInvalid  = errors.New("edge onboarding package invalid")

	// Validation errors for discovered interfaces

	ErrDeviceIPRequired      = errors.New("device IP is required")
	ErrAgentIDRequired       = errors.New("agent ID is required")
	ErrLocalDeviceIPRequired = errors.New("local device IP is required")
	ErrProtocolTypeRequired  = errors.New("protocol type is required")

	// CNPG discovery + topology validation errors.

	ErrDiscoveredInterfaceNil       = errors.New("discovered interface is nil")
	ErrDiscoveredIdentifiersMissing = errors.New("agent_id, poller_id, and device_ip are required")
	ErrTopologyEventNil             = errors.New("topology discovery event is nil")
	ErrTopologyIdentifiersMissing   = errors.New("agent_id, poller_id, local_device_ip, and protocol_type are required")

	// Edge onboarding helpers.

	ErrEdgePackageIDRequired = errors.New("edge onboarding package id is required")
	ErrEdgeEventNil          = errors.New("edge onboarding event is nil")

	// Timeseries + metrics validation.

	ErrTimeseriesMetricNil         = errors.New("timeseries metric is nil")
	ErrTimeseriesColumnRequired    = errors.New("timeseries column is required")
	ErrTimeseriesColumnUnsupported = errors.New("unsupported timeseries column")
	ErrNetflowMetricNil            = errors.New("netflow metric is nil")

	// Registry validation errors.

	ErrPollerStatusNil              = errors.New("poller status nil")
	ErrPollerIDMissing              = errors.New("poller id is required")
	ErrServiceStatusNil             = errors.New("service status nil")
	ErrServiceStatusPollerIDMissing = errors.New("service status poller id is required")
	ErrServiceNil                   = errors.New("service nil")
	ErrServicePollerIDMissing       = errors.New("service poller id required")
	ErrServiceRegistrationEventNil  = errors.New("service registration event is nil")

	// Sweep validation errors.

	ErrSweepStateNil        = errors.New("sweep host state is nil")
	ErrSweepHostIPMissing   = errors.New("host ip is required")
	ErrSweepPollerIDMissing = errors.New("poller id is required")
	ErrSweepAgentIDMissing  = errors.New("agent id is required")

	// Rows helpers.

	ErrCNPGRowsNotInitialized = errors.New("cnpg rows not initialized")

	// TLS helpers.

	ErrCNPGLackingTLSFiles = errors.New("cnpg tls requires cert_file, key_file, and ca_file")
	ErrCNPGAppendCACert    = errors.New("cnpg tls: unable to append CA certificate")
)
