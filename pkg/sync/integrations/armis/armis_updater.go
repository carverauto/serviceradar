package armis

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
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

// RiskLevelStats represents availability statistics for a risk level
type RiskLevelStats struct {
	Total     int `json:"total"`
	Tested    int `json:"tested"`
	Available int `json:"available"`
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

// setServiceRadarCompliant sets the SERVICERADAR_COMPLIANT attribute based on sweep results
func setServiceRadarCompliant(ip string, resultMap map[string]SweepResult, attributes map[string]interface{}) {
	if result, exists := resultMap[ip]; exists {
		attributes["SERVICERADAR_COMPLIANT"] = strconv.FormatBool(!result.Available)
	}
}

// BatchUpdateDeviceAttributes updates multiple devices with sweep result attributes
func (a *ArmisIntegration) BatchUpdateDeviceAttributes(ctx context.Context, devices []Device, sweepResults []SweepResult) error {
	logger.Info().
		Int("devices_count", len(devices)).
		Int("sweep_results_count", len(sweepResults)).
		Msg("Batch updating device attributes for Armis")

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

		// Set SERVICERADAR_COMPLIANT based on sweep results
		setServiceRadarCompliant(ip, resultMap, attributes)

		if len(attributes) > 0 && a.Updater != nil {
			if err := a.Updater.UpdateDeviceCustomAttributes(ctx, devices[i].ID, attributes); err != nil {
				logger.Error().
					Err(err).
					Int("device_id", devices[i].ID).
					Msg("Failed to update attributes for device")
			}
		}
	}

	return nil
}

// UpdateDeviceStatus sends device availability status back to Armis
func (u *DefaultArmisUpdater) UpdateDeviceStatus(ctx context.Context, updates []ArmisDeviceStatus) error {
	if len(updates) == 0 {
		return nil
	}

	accessToken, err := u.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get access token: %w", err)
	}

	type upsertBody struct {
		Upsert struct {
			DeviceID int         `json:"deviceId"`
			Key      string      `json:"key"`
			Value    interface{} `json:"value"`
		} `json:"upsert"`
	}

	operations := make([]upsertBody, 0, len(updates))

	for _, upd := range updates {
		// Only update the SERVICERADAR_COMPLIANT custom field
		op := upsertBody{}
		op.Upsert.DeviceID = upd.DeviceID
		op.Upsert.Key = "SERVICERADAR_COMPLIANT"
		op.Upsert.Value = upd.Available
		operations = append(operations, op)
	}

	bodyBytes, err := json.Marshal(operations)
	if err != nil {
		return fmt.Errorf("failed to marshal payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/v1/devices/custom-properties/_bulk/", u.Config.Endpoint),
		bytes.NewReader(bodyBytes))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", accessToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := u.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated &&
		resp.StatusCode != http.StatusMultiStatus {
		return fmt.Errorf("%w: %d, response: %s", errUnexpectedStatusCode, resp.StatusCode, string(respBody))
	}

	logger.Debug().
		Str("response_body", string(respBody)).
		Msg("Armis bulk update response")

	return nil
}

// UpdateDeviceCustomAttributes updates custom attributes on Armis devices
func (u *DefaultArmisUpdater) UpdateDeviceCustomAttributes(ctx context.Context, deviceID int, attributes map[string]interface{}) error {
	if len(attributes) == 0 {
		return nil
	}

	accessToken, err := u.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get access token: %w", err)
	}

	type upsertBody struct {
		Upsert struct {
			DeviceID int         `json:"deviceId"`
			Key      string      `json:"key"`
			Value    interface{} `json:"value"`
		} `json:"upsert"`
	}

	operations := make([]upsertBody, 0, len(attributes))

	for k, v := range attributes {
		op := upsertBody{}
		op.Upsert.DeviceID = deviceID
		op.Upsert.Key = k
		op.Upsert.Value = v
		operations = append(operations, op)
	}

	bodyBytes, err := json.Marshal(operations)
	if err != nil {
		return fmt.Errorf("failed to marshal payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/v1/devices/custom-properties/_bulk/", u.Config.Endpoint),
		bytes.NewReader(bodyBytes))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", accessToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := u.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated &&
		resp.StatusCode != http.StatusMultiStatus {
		return fmt.Errorf("%w: %d, response: %s", errUnexpectedStatusCode, resp.StatusCode, string(respBody))
	}

	logger.Debug().
		Str("response_body", string(respBody)).
		Msg("Armis custom attribute update response")

	return nil
}
