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
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
)

const (
	unifiDetailAdapterV1Direct      = "unifi.detail.v1.direct"
	unifiDetailAdapterV1WrappedData = "unifi.detail.v1.wrapped_data"
	unifiDetailAdapterV1WrappedNode = "unifi.detail.v1.wrapped_device"
	unifiDetailAdapterLegacyStat    = "unifi.detail.v1.legacy_stat_device"
)

type legacyUniFiDeviceDetailsRecord struct {
	MAC      string `json:"mac"`
	IP       string `json:"ip"`
	Name     string `json:"name"`
	Hostname string `json:"hostname"`
	UniFiDeviceDetails
}

func hasUniFiTopologySignals(details *UniFiDeviceDetails) bool {
	if details == nil {
		return false
	}
	return len(details.normalizedLLDPTable()) > 0 ||
		len(details.normalizedPortTable()) > 0 ||
		details.Uplink.upstreamDeviceID() != ""
}

func hasUniFiSupportedDetailShape(details *UniFiDeviceDetails) bool {
	if details == nil {
		return false
	}
	return hasUniFiTopologySignals(details) || len(details.Interfaces.Ports) > 0
}

func (e *DiscoveryEngine) parseUniFiDeviceDetailsWithAdapters(
	job *DiscoveryJob, body []byte) (*UniFiDeviceDetails, error) {
	var direct UniFiDeviceDetails
	if err := json.Unmarshal(body, &direct); err == nil {
		if hasUniFiSupportedDetailShape(&direct) {
			direct.AdapterVersion = unifiDetailAdapterV1Direct
			direct.AdapterShape = "direct"
			return &direct, nil
		}
		e.recordContractParserMismatch(job, "unifi.detail.direct")
	} else {
		e.recordContractParseFailure(job, "unifi.detail.direct", err.Error())
	}

	var wrapped struct {
		Data   UniFiDeviceDetails `json:"data"`
		Device UniFiDeviceDetails `json:"device"`
	}
	if err := json.Unmarshal(body, &wrapped); err == nil {
		if hasUniFiSupportedDetailShape(&wrapped.Data) {
			wrapped.Data.AdapterVersion = unifiDetailAdapterV1WrappedData
			wrapped.Data.AdapterShape = "wrapped_data"
			return &wrapped.Data, nil
		}
		if hasUniFiSupportedDetailShape(&wrapped.Device) {
			wrapped.Device.AdapterVersion = unifiDetailAdapterV1WrappedNode
			wrapped.Device.AdapterShape = "wrapped_device"
			return &wrapped.Device, nil
		}
		e.recordContractParserMismatch(job, "unifi.detail.wrapped")
	} else {
		e.recordContractParseFailure(job, "unifi.detail.wrapped", err.Error())
	}

	topKeys := extractTopLevelJSONKeys(body)
	e.recordContractUnknownTopLevel(job, "unifi.detail", topKeys)
	e.recordContractParserMismatch(job, "unifi.detail.quarantined")
	return nil, ErrUniFiPayloadDriftQuarantined
}

func extractTopLevelJSONKeys(body []byte) []string {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(body, &m); err != nil {
		return nil
	}

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func legacyUniFiStatDeviceURL(apiConfig UniFiAPIConfig, site UniFiSite) (string, error) {
	siteRef := strings.TrimSpace(site.InternalReference)
	if siteRef == "" {
		return "", fmt.Errorf("%w: site %s", ErrUniFiLegacySiteRefMissing, site.Name)
	}

	if !strings.Contains(apiConfig.BaseURL, "/integration/v1") {
		return "", fmt.Errorf("%w: %q", ErrUniFiLegacyBaseURLInvalid, apiConfig.BaseURL)
	}

	return strings.Replace(
		apiConfig.BaseURL,
		"/integration/v1",
		fmt.Sprintf("/api/s/%s/stat/device", siteRef),
		1,
	), nil
}

func (e *DiscoveryEngine) fetchLegacyUniFiDeviceDetailsForSite(
	ctx context.Context,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]legacyUniFiDeviceDetailsRecord, error) {
	legacyURL, err := legacyUniFiStatDeviceURL(apiConfig, site)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, legacyURL, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create legacy details request for site %s: %w", site.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch legacy UniFi device stats for site %s: %w", site.Name, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf(
			"%w: controller %s site %s status %d",
			ErrUniFiLegacyStatsRequestFail,
			apiConfig.Name,
			site.Name,
			resp.StatusCode,
		)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read legacy UniFi device stats for site %s: %w", site.Name, err)
	}

	var legacyResp struct {
		Data []legacyUniFiDeviceDetailsRecord `json:"data"`
	}

	if err := json.Unmarshal(body, &legacyResp); err != nil {
		return nil, fmt.Errorf("failed to parse legacy UniFi device stats for site %s: %w", site.Name, err)
	}

	for i := range legacyResp.Data {
		legacyResp.Data[i].AdapterVersion = unifiDetailAdapterLegacyStat
		legacyResp.Data[i].AdapterShape = "legacy_stat_device"
	}

	return legacyResp.Data, nil
}

func matchLegacyUniFiDeviceDetails(
	device *UniFiDevice,
	records []legacyUniFiDeviceDetailsRecord) *UniFiDeviceDetails {
	if device == nil {
		return nil
	}

	deviceMAC := strings.ToLower(strings.TrimSpace(device.MAC))
	deviceIP := strings.TrimSpace(device.IPAddress)
	deviceName := strings.TrimSpace(device.Name)

	for i := range records {
		record := &records[i]
		switch {
		case deviceMAC != "" && deviceMAC == strings.ToLower(strings.TrimSpace(record.MAC)):
			return &record.UniFiDeviceDetails
		case deviceIP != "" && deviceIP == strings.TrimSpace(record.IP):
			return &record.UniFiDeviceDetails
		case deviceName != "" && deviceName == strings.TrimSpace(record.Name):
			return &record.UniFiDeviceDetails
		case deviceName != "" && deviceName == strings.TrimSpace(record.Hostname):
			return &record.UniFiDeviceDetails
		}
	}

	return nil
}

func applyUniFiDetailAdapterMetadata(metadata map[string]string, details *UniFiDeviceDetails) {
	if metadata == nil || details == nil {
		return
	}
	if strings.TrimSpace(details.AdapterVersion) != "" {
		metadata["source_adapter_version"] = strings.TrimSpace(details.AdapterVersion)
	}
	if strings.TrimSpace(details.AdapterShape) != "" {
		metadata["source_adapter_shape"] = strings.TrimSpace(details.AdapterShape)
	}
}
