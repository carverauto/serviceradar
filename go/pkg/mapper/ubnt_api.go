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

package mapper

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
)

var (
	// ErrNoUniFiNeighborsFound indicates that no neighboring devices were found during UniFi discovery.
	ErrNoUniFiNeighborsFound        = errors.New("no UniFi neighbors found")
	ErrUniFiPayloadDriftQuarantined = errors.New("unifi payload drift quarantined")
	ErrUniFiLegacySiteRefMissing    = errors.New("missing UniFi legacy site reference")
	ErrUniFiLegacyBaseURLInvalid    = errors.New("unifi base URL does not include /integration/v1")
	ErrUniFiLegacyStatsRequestFail  = errors.New("legacy UniFi device stats request failed")
)

// fetchUniFiDevicesForSite fetches devices from a UniFi site and creates a device cache
func (e *DiscoveryEngine) fetchUniFiDevicesForSite(
	ctx context.Context,
	job *DiscoveryJob,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]UniFiDevice, map[string]struct {
	IP       string
	Name     string
	MAC      string
	DeviceID string
}, error) {
	devicesURL := fmt.Sprintf("%s/sites/%s/devices", apiConfig.BaseURL, site.ID)
	devices, err := fetchUniFiPagedData[UniFiDevice](
		ctx,
		client,
		headers,
		devicesURL,
		"devices",
		apiConfig.Name,
		site.Name,
	)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %w", ErrUniFiDevicesRequestFailed, err)
	}

	deviceCache := make(map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	})

	for i := range devices {
		device := &devices[i]

		deviceID := GenerateDeviceID(device.MAC)

		deviceCache[device.ID] = struct {
			IP       string
			Name     string
			MAC      string
			DeviceID string
		}{device.IPAddress, device.Name, device.MAC, deviceID}
	}

	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).Int("device_count", len(devices)).
		Msg("Fetched devices from UniFi API")

	return devices, deviceCache, nil
}

var errUniFiClientsFetchFailed = errors.New("failed to fetch clients")

// fetchUniFiClientsForSite returns every client the Integration v1 /clients
// endpoint reports (wired and wireless); callers split by normalizedType().
func (*DiscoveryEngine) fetchUniFiClientsForSite(
	ctx context.Context,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]UniFiClient, error) {
	clientsURL := fmt.Sprintf("%s/sites/%s/clients", apiConfig.BaseURL, site.ID)
	clients, err := fetchUniFiPagedData[UniFiClient](
		ctx,
		client,
		headers,
		clientsURL,
		"clients",
		apiConfig.Name,
		site.Name,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errUniFiClientsFetchFailed, err)
	}

	return clients, nil
}

// fetchDeviceDetails fetches detailed information for a specific device
func (e *DiscoveryEngine) fetchDeviceDetails(
	ctx context.Context,
	job *DiscoveryJob,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite,
	deviceID string) (*UniFiDeviceDetails, error) {
	detailsURL := fmt.Sprintf("%s/sites/%s/devices/%s", apiConfig.BaseURL, site.ID, deviceID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, detailsURL, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create details request for device %s: %w",
			deviceID, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch details for device %s: %w", deviceID, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w for device %s with status: %d",
			ErrUniFiDeviceDetailsFailed, deviceID, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read details for device %s: %w", deviceID, err)
	}

	details, err := e.parseUniFiDeviceDetailsWithAdapters(job, body)
	if err == nil {
		return details, nil
	}

	if errors.Is(err, ErrUniFiPayloadDriftQuarantined) {
		topKeys := extractTopLevelJSONKeys(body)
		preview := string(body)
		if len(preview) > 1500 {
			preview = preview[:1500]
		}
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("api_name", apiConfig.Name).
			Str("site_name", site.Name).
			Str("device_id", deviceID).
			Int("payload_bytes", len(body)).
			Strs("top_level_keys", topKeys).
			Str("payload_preview", preview).
			Msg("Quarantined UniFi detail payload drift")
	}

	return nil, fmt.Errorf("failed to parse details for device %s: %w", deviceID, err)
}
