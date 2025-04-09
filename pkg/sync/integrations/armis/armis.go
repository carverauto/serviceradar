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

package armis

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// ArmisIntegration manages the Armis API integration.
type ArmisIntegration struct {
	Config     models.SourceConfig
	KvClient   proto.KVServiceClient
	GrpcConn   *grpc.ClientConn
	ServerName string
	// New fields for better configuration
	BoundaryName string // To filter devices by boundary
	PageSize     int    // Number of devices to fetch per page
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

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
	errAuthFailed           = errors.New("authentication failed")
)

// Fetch retrieves devices from Armis and generates sweep config.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	// Get access token
	accessToken, err := a.getAccessToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get access token: %w", err)
	}

	// Start with empty result set
	allDevices := make([]Device, 0)

	// Set default page size if not specified
	if a.PageSize <= 0 {
		a.PageSize = 100
	}

	// Start with first page
	nextPage := 0

	// Build the search query
	searchQuery := fmt.Sprintf("in:devices orderBy=id")

	// Add boundary filter if specified
	if a.BoundaryName != "" {
		searchQuery += fmt.Sprintf(" boundaries:\"%s\"", a.BoundaryName)
	}

	// Paginate through all results
	for {
		// Break if we've reached the end
		if nextPage < 0 {
			break
		}

		// Fetch the current page
		page, err := a.fetchDevicesPage(ctx, accessToken, searchQuery, nextPage, a.PageSize)
		if err != nil {
			return nil, err
		}

		// Add devices to our collection
		allDevices = append(allDevices, page.Data.Results...)

		// Check if there are more pages
		if page.Data.Next != 0 {
			nextPage = page.Data.Next
		} else {
			nextPage = -1 // No more pages
		}

		log.Printf("Fetched %d devices, total so far: %d", page.Data.Count, len(allDevices))
	}

	// Process devices
	data, ips := a.processDevices(allDevices)

	log.Printf("Fetched total of %d devices from Armis", len(allDevices))

	// Generate and write sweep configuration
	a.writeSweepConfig(ctx, ips)

	return data, nil
}

// getAccessToken obtains a temporary access token from Armis.
func (a *ArmisIntegration) getAccessToken(ctx context.Context) (string, error) {
	// Form data must be application/x-www-form-urlencoded
	data := url.Values{}
	data.Set("secret_key", a.Config.Credentials["secret_key"])

	// Create the request
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/v1/access_token/", a.Config.Endpoint),
		strings.NewReader(data.Encode()))
	if err != nil {
		return "", err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	// Send the request
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	// Check response status
	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("%w: %d, response: %s", errUnexpectedStatusCode,
			resp.StatusCode, string(bodyBytes))
	}

	// Parse response
	var tokenResp AccessTokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return "", err
	}

	// Check success status
	if !tokenResp.Success {
		return "", errAuthFailed
	}

	return tokenResp.Data.AccessToken, nil
}

// fetchDevicesPage fetches a single page of devices from the Armis API.
func (a *ArmisIntegration) fetchDevicesPage(ctx context.Context, accessToken, query string, from, length int) (*SearchResponse, error) {
	// Build request URL with query parameters
	reqURL := fmt.Sprintf("%s/api/v1/search/?aql=%s&length=%d",
		a.Config.Endpoint, url.QueryEscape(query), length)

	// Add 'from' parameter if not the first page
	if from > 0 {
		reqURL += fmt.Sprintf("&from=%d", from)
	}

	// Create the request
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, http.NoBody)
	if err != nil {
		return nil, err
	}

	// Set authorization header with token
	req.Header.Set("Authorization", accessToken)
	req.Header.Set("Accept", "application/json")

	// Send the request
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Check response status
	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: %d, response: %s", errUnexpectedStatusCode,
			resp.StatusCode, string(bodyBytes))
	}

	// Parse response
	var searchResp SearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&searchResp); err != nil {
		return nil, err
	}

	// Check success status
	if !searchResp.Success {
		return nil, errors.New("search request unsuccessful")
	}

	return &searchResp, nil
}

// processDevices converts devices to KV data and extracts IPs.
func (a *ArmisIntegration) processDevices(devices []Device) (map[string][]byte, []string) {
	data := make(map[string][]byte)
	ips := make([]string, 0, len(devices))

	for _, device := range devices {
		// Marshal the device to JSON
		value, err := json.Marshal(device)
		if err != nil {
			log.Printf("Failed to marshal device %d: %v", device.ID, err)
			continue
		}

		// Store device in KV with device ID as key
		data[fmt.Sprintf("%d", device.ID)] = value

		// Process IP addresses - might have multiple comma-separated IPs
		if device.IPAddress != "" {
			// Split by comma if multiple IPs
			ipList := strings.Split(device.IPAddress, ",")
			for _, ip := range ipList {
				// Trim spaces
				ip = strings.TrimSpace(ip)
				if ip != "" {
					// Add to sweep list with /32 suffix
					ips = append(ips, ip+"/32")
				}
			}
		}
	}

	return data, ips
}

// writeSweepConfig generates and writes the sweep Config to KV.
func (a *ArmisIntegration) writeSweepConfig(ctx context.Context, ips []string) {
	sweepConfig := models.SweepConfig{
		Networks:      ips,
		Ports:         []int{22, 80, 443, 3306, 5432, 6379, 8080, 8443},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "5m",
		Concurrency:   100,
		Timeout:       "10s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		log.Printf("Failed to marshal sweep config: %v", err)
		return
	}

	configKey := fmt.Sprintf("config/%s/network-sweep", a.ServerName)
	_, err = a.KvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		log.Printf("Failed to write sweep config to %s: %v", configKey, err)

		return
	}

	log.Printf("Wrote sweep config to %s", configKey)
}
