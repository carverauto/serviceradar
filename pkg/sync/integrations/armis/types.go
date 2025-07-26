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

// Package armis pkg/sync/integrations/types.go
package armis

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// SweepResult represents a network sweep result
type SweepResult struct {
	IP        string    `json:"ip"`
	Available bool      `json:"available"`
	Timestamp time.Time `json:"timestamp"`
	RTT       float64   `json:"rtt,omitempty"`      // Round-trip time in milliseconds
	Port      int       `json:"port,omitempty"`     // If this was a TCP sweep
	Protocol  string    `json:"protocol,omitempty"` // "icmp" or "tcp"
	Error     string    `json:"error,omitempty"`    // Any error encountered
}

// ArmisIntegration manages the Armis API integration.
type ArmisIntegration struct {
	// The Armis integration at this time is designed to work with the network sweeper
	// and is not yet a full integration.
	SweeperConfig *models.SweepConfig
	Config        *models.SourceConfig
	KVClient      proto.KVServiceClient
	GRPCConn      *grpc.ClientConn
	ServerName    string
	PageSize      int // Number of devices to fetch per page

	// Interface implementations
	HTTPClient    HTTPClient
	TokenProvider TokenProvider
	DeviceFetcher DeviceFetcher
	KVWriter      KVWriter

	// Interfaces for querying sweep results and updating Armis devices
	SweepQuerier    SRQLQuerier
	Updater         ArmisUpdater
	ResultSubmitter ResultSubmitter

	// Logger
	Logger logger.Logger
}

// AccessTokenResponse represents the Armis API access token response.
type AccessTokenResponse struct {
	Data struct {
		AccessToken   string    `json:"access_token"`
		ExpirationUTC time.Time `json:"expiration_utc"`
	} `json:"data"`
	Success bool `json:"success"`
}

// SearchResponse represents the Armis API search response for devices.
type SearchResponse struct {
	Data struct {
		Count   int         `json:"count"`
		Next    int         `json:"next"`
		Prev    interface{} `json:"prev"`
		Results []Device    `json:"results"`
		Total   int         `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

// Device represents an Armis device as returned by the API.
type Device struct {
	ID               int         `json:"id"`
	IPAddress        string      `json:"ipAddress"`
	MacAddress       string      `json:"macAddress"`
	Name             string      `json:"name"`
	Type             string      `json:"type"`
	Category         string      `json:"category"`
	Manufacturer     string      `json:"manufacturer"`
	Model            string      `json:"model"`
	OperatingSystem  string      `json:"operatingSystem"`
	FirstSeen        time.Time   `json:"firstSeen"`
	LastSeen         time.Time   `json:"lastSeen"`
	RiskLevel        int         `json:"riskLevel"`
	Boundaries       string      `json:"boundaries"`
	Tags             []string    `json:"tags"`
	CustomProperties interface{} `json:"customProperties"`
	BusinessImpact   string      `json:"businessImpact"`
	Visibility       string      `json:"visibility"`
	Site             interface{} `json:"site"`
}

// DeviceWithMetadata represents an Armis device along with ServiceRadar metadata.
// The Metadata field is not provided by the Armis API but is used internally to
// persist additional information such as the Armis device ID.
type DeviceWithMetadata struct {
	Device
	Metadata map[string]string `json:"metadata,omitempty"`
}

// DefaultArmisIntegration provides the default implementations for the interfaces.
type DefaultArmisIntegration struct {
	Config     *models.SourceConfig
	HTTPClient HTTPClient
	Logger     logger.Logger
}

// DefaultKVWriter provides the default implementation for KVWriter.
type DefaultKVWriter struct {
	KVClient   proto.KVServiceClient
	ServerName string
	AgentID    string
	Logger     logger.Logger
}
