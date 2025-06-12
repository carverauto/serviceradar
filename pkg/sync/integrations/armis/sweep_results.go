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

// Package armis pkg/sync/integrations/armis/sweep_results.go
package armis

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
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

// SweepResultsQuery handles querying sweep results via SRQL
type SweepResultsQuery struct {
	APIEndpoint string // ServiceRadar API endpoint
	APIKey      string // API key for authentication
	HTTPClient  HTTPClient
}

// QueryRequest represents the SRQL query request
type QueryRequest struct {
	Query     string `json:"query"`
	Limit     int    `json:"limit,omitempty"`
	Cursor    string `json:"cursor,omitempty"`
	Direction string `json:"direction,omitempty"`
}

// QueryResponse represents the SRQL query response
type QueryResponse struct {
	Results    []map[string]interface{} `json:"results"`
	Pagination struct {
		NextCursor string `json:"next_cursor,omitempty"`
		PrevCursor string `json:"prev_cursor,omitempty"`
		Limit      int    `json:"limit"`
	} `json:"pagination"`
	Error string `json:"error,omitempty"`
}

// NewSweepResultsQuery creates a new sweep results query handler
func NewSweepResultsQuery(apiEndpoint, apiKey string, httpClient HTTPClient) *SweepResultsQuery {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: 30 * time.Second,
		}
	}

	return &SweepResultsQuery{
		APIEndpoint: apiEndpoint,
		APIKey:      apiKey,
		HTTPClient:  httpClient,
	}
}

// GetTodaysSweepResults queries for today's sweep results
func (s *SweepResultsQuery) GetTodaysSweepResults(ctx context.Context) ([]SweepResult, error) {
	query := "show sweep_results where date(timestamp) = TODAY"
	return s.executeSweepQuery(ctx, query, 1000) // Get up to 1000 results
}

// GetSweepResultsForIPs queries sweep results for specific IP addresses
func (s *SweepResultsQuery) GetSweepResultsForIPs(ctx context.Context, ips []string) ([]SweepResult, error) {
	if len(ips) == 0 {
		return []SweepResult{}, nil
	}

	// Build IP list for the IN clause
	ipList := ""
	for i, ip := range ips {
		if i > 0 {
			ipList += ", "
		}
		ipList += fmt.Sprintf("'%s'", ip)
	}

	query := fmt.Sprintf("show sweep_results where ip IN (%s) and date(timestamp) = TODAY", ipList)
	return s.executeSweepQuery(ctx, query, len(ips)*2) // Allow for multiple results per IP
}

// GetRecentSweepResults queries for sweep results within a time range
func (s *SweepResultsQuery) GetRecentSweepResults(ctx context.Context, hours int) ([]SweepResult, error) {
	// For now, we'll use TODAY as SRQL doesn't support relative time queries yet
	// In the future, this could be enhanced to support actual time ranges
	query := "show sweep_results where date(timestamp) = TODAY order by timestamp desc"
	return s.executeSweepQuery(ctx, query, 1000)
}

// executeSweepQuery executes an SRQL query and returns sweep results
func (s *SweepResultsQuery) executeSweepQuery(ctx context.Context, query string, limit int) ([]SweepResult, error) {
	var allResults []SweepResult
	cursor := ""

	for {
		// Prepare the query request
		queryReq := QueryRequest{
			Query:  query,
			Limit:  limit,
			Cursor: cursor,
		}

		// Execute the query
		response, err := s.executeQuery(ctx, queryReq)
		if err != nil {
			return nil, fmt.Errorf("failed to execute query: %w", err)
		}

		// Convert results
		results, err := s.convertToSweepResults(response.Results)
		if err != nil {
			return nil, fmt.Errorf("failed to convert results: %w", err)
		}

		allResults = append(allResults, results...)

		// Check if there are more results
		if response.Pagination.NextCursor == "" || len(results) == 0 {
			break
		}

		cursor = response.Pagination.NextCursor
	}

	return allResults, nil
}

// executeQuery executes an SRQL query against the ServiceRadar API
func (s *SweepResultsQuery) executeQuery(ctx context.Context, queryReq QueryRequest) (*QueryResponse, error) {
	// Marshal the request
	reqBody, err := json.Marshal(queryReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal query request: %w", err)
	}

	// Create the HTTP request
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/query", s.APIEndpoint),
		bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// Set headers
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", s.APIKey)

	// Execute the request
	resp, err := s.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to execute request: %w", err)
	}
	defer resp.Body.Close()

	// Read the response
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Check status code
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(body))
	}

	// Parse the response
	var queryResp QueryResponse
	if err := json.Unmarshal(body, &queryResp); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	if queryResp.Error != "" {
		return nil, fmt.Errorf("query error: %s", queryResp.Error)
	}

	return &queryResp, nil
}

// convertToSweepResults converts raw query results to SweepResult structs
func (s *SweepResultsQuery) convertToSweepResults(rawResults []map[string]interface{}) ([]SweepResult, error) {
	results := make([]SweepResult, 0, len(rawResults))

	for _, raw := range rawResults {
		result := SweepResult{}

		// Extract IP
		if ip, ok := raw["ip"].(string); ok {
			result.IP = ip
		}

		// Extract availability
		if available, ok := raw["available"].(bool); ok {
			result.Available = available
		}

		// Extract timestamp
		if ts, ok := raw["timestamp"].(string); ok {
			if parsed, err := time.Parse(time.RFC3339, ts); err == nil {
				result.Timestamp = parsed
			}
		}

		// Extract RTT (round-trip time)
		if rtt, ok := raw["rtt"].(float64); ok {
			result.RTT = rtt
		}

		// Extract port
		if port, ok := raw["port"].(float64); ok {
			result.Port = int(port)
		}

		// Extract protocol
		if protocol, ok := raw["protocol"].(string); ok {
			result.Protocol = protocol
		}

		// Extract error
		if errMsg, ok := raw["error"].(string); ok {
			result.Error = errMsg
		}

		results = append(results, result)
	}

	return results, nil
}

// GetAvailabilityStats returns availability statistics for the given IPs
func (s *SweepResultsQuery) GetAvailabilityStats(ctx context.Context, ips []string) (map[string]bool, error) {
	results, err := s.GetSweepResultsForIPs(ctx, ips)
	if err != nil {
		return nil, err
	}

	// Create a map of IP to availability status
	// Use the most recent result for each IP
	availabilityMap := make(map[string]bool)
	latestTimestamp := make(map[string]time.Time)

	for _, result := range results {
		if existing, exists := latestTimestamp[result.IP]; !exists || result.Timestamp.After(existing) {
			availabilityMap[result.IP] = result.Available
			latestTimestamp[result.IP] = result.Timestamp
		}
	}

	return availabilityMap, nil
}

// ArmisDeviceStatus represents the status of a device to be sent to Armis
type ArmisDeviceStatus struct {
	DeviceID        int       `json:"device_id"`
	IP              string    `json:"ip"`
	Available       bool      `json:"available"`
	LastChecked     time.Time `json:"last_checked"`
	RTT             float64   `json:"rtt,omitempty"`
	ServiceRadarURL string    `json:"serviceradar_url,omitempty"`
}

// PrepareArmisUpdate prepares device status updates for Armis based on sweep results
func (a *ArmisIntegration) PrepareArmisUpdate(ctx context.Context, devices []Device, sweepResults []SweepResult) []ArmisDeviceStatus {
	// Create a map of IP to most recent sweep result
	resultMap := make(map[string]SweepResult)
	for _, result := range sweepResults {
		if existing, exists := resultMap[result.IP]; !exists || result.Timestamp.After(existing.Timestamp) {
			resultMap[result.IP] = result
		}
	}

	// Prepare status updates
	var updates []ArmisDeviceStatus
	for _, device := range devices {
		// Extract the first IP from the device (Armis can have comma-separated IPs)
		ip := extractFirstIP(device.IPAddress)
		if ip == "" {
			continue
		}

		status := ArmisDeviceStatus{
			DeviceID:        device.ID,
			IP:              ip,
			Available:       false, // Default to unavailable
			ServiceRadarURL: fmt.Sprintf("%s/api/query?q=show+sweep_results+where+ip='%s'", a.Config.Endpoint, ip),
		}

		// Check if we have sweep results for this IP
		if result, exists := resultMap[ip]; exists {
			status.Available = result.Available
			status.LastChecked = result.Timestamp
			status.RTT = result.RTT
		}

		updates = append(updates, status)
	}

	return updates
}

// extractFirstIP extracts the first IP from a potentially comma-separated list
func extractFirstIP(ipList string) string {
	ips := strings.Split(ipList, ",")
	if len(ips) > 0 {
		return strings.TrimSpace(ips[0])
	}
	return ""
}

// Example usage function showing how to integrate with the existing Fetch method
func (a *ArmisIntegration) FetchWithSweepResults(ctx context.Context) (map[string][]byte, error) {
	// First, perform the regular fetch to get devices and create sweep config
	data, err := a.Fetch(ctx)
	if err != nil {
		return nil, err
	}

	// Wait a bit for sweep results to be available (in production, this would be scheduled differently)
	log.Println("Waiting for sweep results to be available...")
	time.Sleep(5 * time.Second)

	// Create a sweep results query handler
	sweepQuery := NewSweepResultsQuery(
		a.Config.Endpoint,               // Assuming this points to ServiceRadar API
		a.Config.Credentials["api_key"], // Assuming API key is stored here
		a.HTTPClient,
	)

	// Get today's sweep results
	sweepResults, err := sweepQuery.GetTodaysSweepResults(ctx)
	if err != nil {
		log.Printf("Failed to get sweep results: %v", err)
		// Don't fail the entire operation if we can't get sweep results
		return data, nil
	}

	log.Printf("Retrieved %d sweep results", len(sweepResults))

	// Get availability stats for our devices
	var deviceIPs []string
	for _, deviceData := range data {
		var device Device
		if err := json.Unmarshal(deviceData, &device); err == nil {
			if ip := extractFirstIP(device.IPAddress); ip != "" {
				deviceIPs = append(deviceIPs, ip)
			}
		}
	}

	availabilityMap, err := sweepQuery.GetAvailabilityStats(ctx, deviceIPs)
	if err != nil {
		log.Printf("Failed to get availability stats: %v", err)
		return data, nil
	}

	// Log availability stats
	available := 0
	for _, isAvailable := range availabilityMap {
		if isAvailable {
			available++
		}
	}
	log.Printf("Device availability: %d/%d devices are reachable", available, len(availabilityMap))

	// TODO: In the next phase, send these results back to Armis using their API

	return data, nil
}

// FetchAndCorrelate fetches devices from Armis and correlates with sweep results
func (e *ArmisIntegration) FetchAndCorrelate(ctx context.Context) (map[string][]byte, error) {
	// First, perform the regular fetch
	data, err := e.Fetch(ctx)
	if err != nil {
		return nil, err
	}

	// Query sweep results
	sweepResults, err := e.SweepQuerier.GetTodaysSweepResults(ctx)
	if err != nil {
		// Log but don't fail if we can't get sweep results
		log.Printf("Failed to get sweep results: %v", err)
		return data, nil
	}

	// Extract devices from the fetched data
	var devices []Device
	for _, deviceData := range data {
		var device Device
		if err := json.Unmarshal(deviceData, &device); err == nil {
			devices = append(devices, device)
		}
	}

	// Prepare status updates
	updates := e.PrepareArmisUpdate(ctx, devices, sweepResults)

	// Send updates back to Armis if we have an updater
	if e.Updater != nil {
		if err := e.Updater.UpdateDeviceStatus(ctx, updates); err != nil {
			log.Printf("Failed to update device status in Armis: %v", err)
		}
	}

	// Enrich the original data with sweep results
	enrichedData := make(map[string][]byte)
	for key, deviceData := range data {
		enrichedData[key] = deviceData
	}

	// Add sweep results as a special entry
	if sweepResultsData, err := json.Marshal(sweepResults); err == nil {
		enrichedData["_sweep_results"] = sweepResultsData
	}

	return enrichedData, nil
}

// SyncLoop implements a continuous sync loop between Armis and ServiceRadar
func (e *ArmisIntegration) SyncLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Initial sync
	if _, err := e.FetchAndCorrelate(ctx); err != nil {
		log.Printf("Initial sync failed: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			log.Println("Sync loop stopped")
			return

		case <-ticker.C:
			log.Println("Running scheduled Armis sync...")

			if _, err := e.FetchAndCorrelate(ctx); err != nil {
				log.Printf("Scheduled sync failed: %v", err)
			}
		}
	}
}

// GetDeviceAvailabilityReport generates a report of device availability
func (e *ArmisIntegration) GetDeviceAvailabilityReport(ctx context.Context) (*AvailabilityReport, error) {
	// Fetch current devices from Armis
	data, err := e.Fetch(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch devices: %w", err)
	}

	// Extract devices and IPs
	var devices []Device
	var allIPs []string

	for _, deviceData := range data {
		var device Device
		if err := json.Unmarshal(deviceData, &device); err == nil {
			devices = append(devices, device)
			if ip := extractFirstIP(device.IPAddress); ip != "" {
				allIPs = append(allIPs, ip)
			}
		}
	}

	// Get availability stats
	availStats, err := e.SweepQuerier.GetAvailabilityStats(ctx, allIPs)
	if err != nil {
		return nil, fmt.Errorf("failed to get availability stats: %w", err)
	}

	// Build report
	report := &AvailabilityReport{
		Timestamp:     time.Now(),
		TotalDevices:  len(devices),
		DevicesWithIP: len(allIPs),
		TestedDevices: len(availStats),
	}

	// Calculate statistics
	for _, isAvailable := range availStats {
		if isAvailable {
			report.AvailableDevices++
		}
	}

	if report.TestedDevices > 0 {
		report.AvailabilityPercentage = float64(report.AvailableDevices) / float64(report.TestedDevices) * 100
	}

	// Group by risk level (if available)
	report.ByRiskLevel = make(map[string]*RiskLevelStats)
	for _, device := range devices {
		riskLevel := getRiskLevelCategory(device.RiskLevel)

		if _, exists := report.ByRiskLevel[riskLevel]; !exists {
			report.ByRiskLevel[riskLevel] = &RiskLevelStats{}
		}

		stats := report.ByRiskLevel[riskLevel]
		stats.Total++

		if ip := extractFirstIP(device.IPAddress); ip != "" {
			if available, tested := availStats[ip]; tested {
				stats.Tested++
				if available {
					stats.Available++
				}
			}
		}
	}

	return report, nil
}

// AvailabilityReport represents a device availability report
type AvailabilityReport struct {
	Timestamp              time.Time                  `json:"timestamp"`
	TotalDevices           int                        `json:"total_devices"`
	DevicesWithIP          int                        `json:"devices_with_ip"`
	TestedDevices          int                        `json:"tested_devices"`
	AvailableDevices       int                        `json:"available_devices"`
	AvailabilityPercentage float64                    `json:"availability_percentage"`
	ByRiskLevel            map[string]*RiskLevelStats `json:"by_risk_level,omitempty"`
}

// RiskLevelStats represents availability statistics for a risk level
type RiskLevelStats struct {
	Total     int `json:"total"`
	Tested    int `json:"tested"`
	Available int `json:"available"`
}

// getRiskLevelCategory categorizes risk levels
func getRiskLevelCategory(riskLevel int) string {
	switch {
	case riskLevel >= 8:
		return "critical"
	case riskLevel >= 5:
		return "high"
	case riskLevel >= 3:
		return "medium"
	default:
		return "low"
	}
}

// BatchUpdateDeviceAttributes updates multiple devices with sweep result attributes
func (e *ArmisIntegration) BatchUpdateDeviceAttributes(ctx context.Context, devices []Device, sweepResults []SweepResult) error {
	// Create a map for quick lookup
	resultMap := make(map[string]SweepResult)
	for _, result := range sweepResults {
		resultMap[result.IP] = result
	}

	// Update each device
	for _, device := range devices {
		ip := extractFirstIP(device.IPAddress)
		if ip == "" {
			continue
		}

		attributes := make(map[string]interface{})

		if result, exists := resultMap[ip]; exists {
			attributes["serviceradar_available"] = result.Available
			attributes["serviceradar_last_checked"] = result.Timestamp.Format(time.RFC3339)

			if result.Available && result.RTT > 0 {
				attributes["serviceradar_rtt_ms"] = result.RTT
			}

			if result.Error != "" {
				attributes["serviceradar_last_error"] = result.Error
			}
		}

		if len(attributes) > 0 && e.Updater != nil {
			if err := e.Updater.UpdateDeviceCustomAttributes(ctx, device.ID, attributes); err != nil {
				log.Printf("Failed to update attributes for device %d: %v", device.ID, err)
				// Continue with other devices
			}
		}
	}

	return nil
}
