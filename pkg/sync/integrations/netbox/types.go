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

package netbox

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// SRQLQuerier defines the interface for querying device states from ServiceRadar.
// This is a local interface to avoid importing pkg/sync and creating a cycle.
type SRQLQuerier interface {
	GetDeviceStatesBySource(ctx context.Context, source string) ([]DeviceState, error)
}

// ResultSubmitter defines the interface for submitting sweep results and retraction events.
// This is a local interface to avoid importing pkg/sync and creating a cycle.
type ResultSubmitter interface {
	SubmitSweepResult(ctx context.Context, result *models.SweepResult) error
	SubmitBatchSweepResults(ctx context.Context, results []*models.SweepResult) error
}

// DeviceState represents the consolidated state of a device from the unified view.
// It's used by integrations to check for retractions.
type DeviceState struct {
	DeviceID    string
	IP          string
	IsAvailable bool
	Metadata    map[string]interface{}
}

// NetboxIntegration manages the NetBox API integration.
type NetboxIntegration struct {
	Config          *models.SourceConfig
	KvClient        proto.KVServiceClient // For writing sweep Config
	GrpcConn        *grpc.ClientConn      // Connection to reuse
	ServerName      string
	ExpandSubnets   bool
	Querier         SRQLQuerier     // Querier for sweep results
	ResultSubmitter ResultSubmitter // For submitting retraction events
}

// Device represents a NetBox device as returned by the API.
type Device struct {
	ID         int    `json:"id"`
	Name       string `json:"name"`
	DeviceType struct {
		ID           int `json:"id"`
		Manufacturer struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
		} `json:"manufacturer"`
		Model string `json:"model"`
	} `json:"device_type"`
	Role struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"role"`
	Tenant struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"tenant"`
	Site struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"site"`
	Status struct {
		Value string `json:"value"`
		Label string `json:"label"`
	} `json:"status"`
	PrimaryIP4 struct {
		ID      int    `json:"id"`
		Address string `json:"address"`
	} `json:"primary_ip4"`
	PrimaryIP6  interface{} `json:"primary_ip6"` // Can be null or an object
	Description string      `json:"description"`
	Created     string      `json:"created"`
	LastUpdated string      `json:"last_updated"`
}

// DeviceResponse represents the NetBox API response.
type DeviceResponse struct {
	Results  []Device `json:"results"`
	Count    int      `json:"count"`
	Next     string   `json:"next"`     // Pagination URL
	Previous string   `json:"previous"` // Pagination URL
}
