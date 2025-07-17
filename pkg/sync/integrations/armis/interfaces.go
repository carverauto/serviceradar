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

//go:generate mockgen -destination=mock_armis.go -package=armis github.com/carverauto/serviceradar/pkg/sync/integrations/armis HTTPClient,TokenProvider,DeviceFetcher,KVWriter,SRQLQuerier,ArmisUpdater,ResultSubmitter

// DeviceState represents the consolidated state of a device from the unified view.
// It's used by integrations to check for retractions.
type DeviceState struct {
	DeviceID    string
	IP          string
	IsAvailable bool
	Metadata    map[string]interface{}
}

// DeviceAttributeUpdate represents a device update operation
type DeviceAttributeUpdate struct {
	DeviceID   int
	Attributes map[string]interface{}
}

// ArmisUpdater defines the interface for updating device status in Armis
type ArmisUpdater interface {
	// UpdateDeviceStatus sends device availability status back to Armis
	UpdateDeviceStatus(ctx context.Context, updates []ArmisDeviceStatus) error

	// UpdateDeviceCustomAttributes updates custom attributes on Armis devices
	UpdateDeviceCustomAttributes(ctx context.Context, deviceID int, attributes map[string]interface{}) error

	// UpdateMultipleDeviceCustomAttributes updates custom attributes for multiple devices in a single bulk operation
	UpdateMultipleDeviceCustomAttributes(ctx context.Context, updates []DeviceAttributeUpdate) error
}

// HTTPClient defines the interface for making HTTP requests.
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

// SRQLQuerier defines the interface for querying the ServiceRadar QL service.
// This is a local interface to avoid importing pkg/sync and creating a cycle.
type SRQLQuerier interface {
	GetDeviceStatesBySource(ctx context.Context, source string) ([]DeviceState, error)
}

// ResultSubmitter defines the interface for submitting sweep results and retraction events.
// This is a local interface to avoid importing pkg/sync and creating a cycle.
type ResultSubmitter interface {
	SubmitSweepResult(ctx context.Context, result *models.DeviceUpdate) error
	SubmitBatchSweepResults(ctx context.Context, results []*models.DeviceUpdate) error
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
