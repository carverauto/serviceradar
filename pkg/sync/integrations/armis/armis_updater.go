package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
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
func (a *ArmisIntegration) PrepareArmisUpdate(_ context.Context, devices []Device, sweepResults []SweepResult) []ArmisDeviceStatus {
	// Create a map of IP to most recent sweep result
	resultMap := make(map[string]SweepResult)

	for _, result := range sweepResults {
		if existing, exists := resultMap[result.IP]; !exists || result.Timestamp.After(existing.Timestamp) {
			resultMap[result.IP] = result
		}
	}

	// Prepare status updates
	updates := make([]ArmisDeviceStatus, 0, len(devices))

	for i := range devices {
		// Extract the first IP from the device (Armis can have comma-separated IPs)
		ip := extractFirstIP(devices[i].IPAddress)
		if ip == "" {
			continue
		}

		status := ArmisDeviceStatus{
			DeviceID:        devices[i].ID,
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

		if err = json.Unmarshal(deviceData, &device); err == nil {
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

	for i := range devices {
		riskLevel := getRiskLevelCategory(devices[i].RiskLevel)

		if _, exists := report.ByRiskLevel[riskLevel]; !exists {
			report.ByRiskLevel[riskLevel] = &RiskLevelStats{}
		}

		stats := report.ByRiskLevel[riskLevel]
		stats.Total++

		if ip := extractFirstIP(devices[i].IPAddress); ip != "" {
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
	for i := range devices {
		ip := extractFirstIP(devices[i].IPAddress)
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
			if err := a.Updater.UpdateDeviceCustomAttributes(ctx, devices[i].ID, attributes); err != nil {
				log.Printf("Failed to update attributes for device %d: %v", devices[i].ID, err)
			}
		}
	}

	return nil
}

// UpdateDeviceStatus sends device availability status back to Armis
func (*DefaultArmisUpdater) UpdateDeviceStatus(_ context.Context, updates []ArmisDeviceStatus) error {
	// TODO: Implement based on Armis API documentation
	log.Printf("UpdateDeviceStatus called with %d updates (not implemented)", len(updates))
	return nil
}

// UpdateDeviceCustomAttributes updates custom attributes on Armis devices
func (*DefaultArmisUpdater) UpdateDeviceCustomAttributes(_ context.Context, deviceID int, attributes map[string]interface{}) error {
	// TODO: Implement based on Armis API documentation
	log.Printf("UpdateDeviceCustomAttributes called for device %d (not implemented)", deviceID)

	// print attributes for debugging
	log.Printf("Attributes: %v", attributes)

	return nil
}
