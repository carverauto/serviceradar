package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/carverauto/serviceradar/pkg/models"
	"log"
	"net/http"
	"strings"
	"time"
)

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
func (a *ArmisIntegration) FetchAndCorrelate(ctx context.Context) (map[string][]byte, error) {
	// First, perform the regular fetch
	data, err := a.Fetch(ctx)
	if err != nil {
		return nil, err
	}

	// Query sweep results
	sweepResults, err := a.SweepQuerier.GetTodaysSweepResults(ctx)
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
	updates := a.PrepareArmisUpdate(ctx, devices, sweepResults)

	// Send updates back to Armis if we have an updater
	if a.Updater != nil {
		if err := a.Updater.UpdateDeviceStatus(ctx, updates); err != nil {
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
func (a *ArmisIntegration) SyncLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Initial sync
	if _, err := a.FetchAndCorrelate(ctx); err != nil {
		log.Printf("Initial sync failed: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			log.Println("Sync loop stopped")
			return

		case <-ticker.C:
			log.Println("Running scheduled Armis sync...")

			if _, err := a.FetchAndCorrelate(ctx); err != nil {
				log.Printf("Scheduled sync failed: %v", err)
			}
		}
	}
}

// GetDeviceAvailabilityReport generates a report of device availability
func (a *ArmisIntegration) GetDeviceAvailabilityReport(ctx context.Context) (*AvailabilityReport, error) {
	// Fetch current devices from Armis
	data, err := a.Fetch(ctx)
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
	availStats, err := a.SweepQuerier.GetAvailabilityStats(ctx, allIPs)
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

// DefaultArmisUpdater implements the ArmisUpdater interface
type DefaultArmisUpdater struct {
	Config        *models.SourceConfig
	HTTPClient    HTTPClient
	TokenProvider TokenProvider
}

// NewArmisUpdater creates a new Armis updater
func NewArmisUpdater(config *models.SourceConfig, httpClient HTTPClient, tokenProvider TokenProvider) ArmisUpdater {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: 30 * time.Second,
		}
	}

	return &DefaultArmisUpdater{
		Config:        config,
		HTTPClient:    httpClient,
		TokenProvider: tokenProvider,
	}
}

// BatchUpdateDeviceAttributes updates multiple devices with sweep result attributes
func (a *ArmisIntegration) BatchUpdateDeviceAttributes(ctx context.Context, devices []Device, sweepResults []SweepResult) error {
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

		if len(attributes) > 0 && a.Updater != nil {
			if err := a.Updater.UpdateDeviceCustomAttributes(ctx, device.ID, attributes); err != nil {
				log.Printf("Failed to update attributes for device %d: %v", device.ID, err)
				// Continue with other devices
			}
		}
	}

	return nil
}

// UpdateDeviceStatus sends device availability status back to Armis
func (u *DefaultArmisUpdater) UpdateDeviceStatus(ctx context.Context, updates []ArmisDeviceStatus) error {
	// TODO: Implement based on Armis API documentation
	log.Printf("UpdateDeviceStatus called with %d updates (not implemented)", len(updates))
	return nil
}

// UpdateDeviceCustomAttributes updates custom attributes on Armis devices
func (u *DefaultArmisUpdater) UpdateDeviceCustomAttributes(ctx context.Context, deviceID int, attributes map[string]interface{}) error {
	// TODO: Implement based on Armis API documentation
	log.Printf("UpdateDeviceCustomAttributes called for device %d (not implemented)", deviceID)
	return nil
}
