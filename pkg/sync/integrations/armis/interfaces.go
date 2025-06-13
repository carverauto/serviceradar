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

// Package armis pkg/sync/integrations/interfaces.go
package armis

import (
	"context"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_armis.go -package=armis github.com/carverauto/serviceradar/pkg/sync/integrations/armis HTTPClient,TokenProvider,DeviceFetcher,KVWriter,SweepResultsQuerier,ArmisUpdater

// SweepResultsQuerier defines the interface for querying sweep results
type SweepResultsQuerier interface {
	// GetTodaysSweepResults queries for all sweep results from today
	GetTodaysSweepResults(ctx context.Context) ([]SweepResult, error)

	// GetSweepResultsForIPs queries sweep results for specific IP addresses
	GetSweepResultsForIPs(ctx context.Context, ips []string) ([]SweepResult, error)

	// GetRecentSweepResults queries for sweep results within a time range
	GetRecentSweepResults(ctx context.Context, hours int) ([]SweepResult, error)

	// GetAvailabilityStats returns a map of IP to availability status
	GetAvailabilityStats(ctx context.Context, ips []string) (map[string]bool, error)
}

// ArmisUpdater defines the interface for updating device status in Armis
type ArmisUpdater interface {
	// UpdateDeviceStatus sends device availability status back to Armis
	UpdateDeviceStatus(ctx context.Context, updates []ArmisDeviceStatus) error

	// UpdateDeviceCustomAttributes updates custom attributes on Armis devices
	UpdateDeviceCustomAttributes(ctx context.Context, deviceID int, attributes map[string]interface{}) error
}

// HTTPClient defines the interface for making HTTP requests.
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

// TokenProvider defines the interface for obtaining access tokens.
type TokenProvider interface {
	GetAccessToken(ctx context.Context) (string, error)
}

// DeviceFetcher defines the interface for fetching devices.
type DeviceFetcher interface {
	FetchDevicesPage(ctx context.Context, accessToken, query string, from, length int) (*SearchResponse, error)
}

// KVWriter defines the interface for writing to KV store.
type KVWriter interface {
	WriteSweepConfig(ctx context.Context, sweepConfig *models.SweepConfig) error
}
