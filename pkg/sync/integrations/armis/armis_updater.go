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

// setServiceRadarCompliant sets the custom field attribute based on sweep results
func (a *ArmisIntegration) setServiceRadarCompliant(ip string, resultMap map[string]SweepResult, attributes map[string]interface{}) {
	if result, exists := resultMap[ip]; exists {
		attributes[a.Config.CustomField] = strconv.FormatBool(!result.Available)
	}
}

const (
	// Default batch size for bulk updates to prevent API overload
	defaultBatchSize = 1000
)

// BatchUpdateDeviceAttributes updates multiple devices with sweep result attributes in batches
func (a *ArmisIntegration) BatchUpdateDeviceAttributes(ctx context.Context, devices []Device, sweepResults []SweepResult) error {
	logger.Info().
		Int("devices_count", len(devices)).
		Int("sweep_results_count", len(sweepResults)).
		Msg("Batch updating device attributes for Armis")

	if a.Updater == nil {
		logger.Warn().Msg("Armis updater not configured, skipping device attribute updates")
		return nil
	}

	// Create a map for quick lookup
	resultMap := make(map[string]SweepResult)
	for _, result := range sweepResults {
		resultMap[result.IP] = result
	}

	// Prepare all device updates with attributes
	var updates []DeviceAttributeUpdate

	for i := range devices {
		ip := extractFirstIP(devices[i].IPAddress)
		if ip == "" {
			continue
		}

		attributes := make(map[string]interface{})
		a.setServiceRadarCompliant(ip, resultMap, attributes)

		if len(attributes) > 0 {
			updates = append(updates, DeviceAttributeUpdate{
				DeviceID:   devices[i].ID,
				Attributes: attributes,
			})
		}
	}

	if len(updates) == 0 {
		logger.Info().Msg("No device updates required")
		return nil
	}

	// Process updates in chunks
	return a.processDeviceUpdatesInBatches(ctx, updates, defaultBatchSize)
}

// processDeviceUpdatesInBatches processes device updates in configurable batch sizes
func (a *ArmisIntegration) processDeviceUpdatesInBatches(ctx context.Context, updates []DeviceAttributeUpdate, batchSize int) error {
	totalUpdates := len(updates)
	logger.Info().
		Int("total_updates", totalUpdates).
		Int("batch_size", batchSize).
		Msg("Processing device updates in batches")

	for i := 0; i < totalUpdates; i += batchSize {
		end := i + batchSize
		if end > totalUpdates {
			end = totalUpdates
		}

		batch := updates[i:end]
		batchNum := (i / batchSize) + 1
		totalBatches := (totalUpdates + batchSize - 1) / batchSize

		logger.Info().
			Int("batch_number", batchNum).
			Int("total_batches", totalBatches).
			Int("batch_size", len(batch)).
			Msg("Processing device update batch")

		if err := a.processSingleBatch(ctx, batch); err != nil {
			logger.Error().
				Err(err).
				Int("batch_number", batchNum).
				Int("batch_size", len(batch)).
				Msg("Failed to process device update batch")

			return fmt.Errorf("failed to process batch %d: %w", batchNum, err)
		}

		logger.Info().
			Int("batch_number", batchNum).
			Int("total_batches", totalBatches).
			Msg("Successfully processed device update batch")
	}

	logger.Info().
		Int("total_updates_processed", totalUpdates).
		Msg("Completed all device attribute updates")

	return nil
}

// processSingleBatch processes a single batch of device updates using the optimized bulk API
func (a *ArmisIntegration) processSingleBatch(ctx context.Context, batch []DeviceAttributeUpdate) error {
	if len(batch) == 0 {
		return nil
	}

	// Use the new optimized bulk update method
	return a.Updater.UpdateMultipleDeviceCustomAttributes(ctx, batch)
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
		// Only update the custom field
		op := upsertBody{}
		op.Upsert.DeviceID = upd.DeviceID
		op.Upsert.Key = u.Config.CustomField
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

// UpdateMultipleDeviceCustomAttributes updates custom attributes for multiple devices in a single bulk operation
func (u *DefaultArmisUpdater) UpdateMultipleDeviceCustomAttributes(ctx context.Context, updates []DeviceAttributeUpdate) error {
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

	var operations []upsertBody

	// Build operations from all device updates
	for _, update := range updates {
		for key, value := range update.Attributes {
			op := upsertBody{}
			op.Upsert.DeviceID = update.DeviceID
			op.Upsert.Key = key
			op.Upsert.Value = value
			operations = append(operations, op)
		}
	}

	if len(operations) == 0 {
		return nil
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

	logger.Info().
		Int("devices_updated", len(updates)).
		Int("total_operations", len(operations)).
		Str("response_body", string(respBody)).
		Msg("Bulk device attributes update completed")

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
