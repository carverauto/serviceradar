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

// Package discovery pkg/discovery/interfaces.go
package mapper

import "context"

// DiscoveryEngine is the main interface for network discovery operations
type DiscoveryEngine interface {
	// Start initializes and starts the discovery engine
	Start(ctx context.Context) error

	// Stop gracefully shuts down the discovery engine
	Stop(ctx context.Context) error

	// StartDiscovery initiates a discovery operation with the given parameters
	StartDiscovery(ctx context.Context, params *DiscoveryParams) (string, error)

	// GetDiscoveryStatus retrieves the status of a discovery operation
	GetDiscoveryStatus(ctx context.Context, discoveryID string) (*DiscoveryStatus, error)

	// GetDiscoveryResults retrieves the results of a completed discovery operation
	GetDiscoveryResults(ctx context.Context, discoveryID string, includeRawData bool) (*DiscoveryResults, error)

	// CancelDiscovery cancels an in-progress discovery operation
	CancelDiscovery(ctx context.Context, discoveryID string) error
}

// Publisher defines the interface for publishing discovered data to streams
type Publisher interface {
	// PublishDevice publishes a discovered device to the appropriate stream
	PublishDevice(ctx context.Context, device *DiscoveredDevice) error

	// PublishInterface publishes a discovered interface to the appropriate stream
	PublishInterface(ctx context.Context, iface *DiscoveredInterface) error

	// PublishTopologyLink publishes a discovered topology link to the appropriate stream
	PublishTopologyLink(ctx context.Context, link *TopologyLink) error
}
