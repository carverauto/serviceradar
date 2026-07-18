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
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

// createUniFiClient initializes an HTTP client for UniFi API calls with configured timeout and TLS settings.
func (e *DiscoveryEngine) createUniFiClient(apiConfig UniFiAPIConfig) *http.Client {
	return &http.Client{
		Timeout: e.config.Timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: apiConfig.InsecureSkipVerify, //nolint:gosec // G402: Allow insecure connections to Ubiquti devices
			},
		},
	}
}

func (e *DiscoveryEngine) fetchUniFiSites(ctx context.Context, job *DiscoveryJob, apiConfig UniFiAPIConfig) ([]UniFiSite, error) {
	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Msg("Fetching sites for UniFi API")

	// Check cache
	job.mu.RLock()

	if sites, exists := job.uniFiSiteCache[apiConfig.BaseURL]; exists {
		job.mu.RUnlock()
		e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Msg("Using cached sites")

		return sites, nil
	}

	job.mu.RUnlock()

	client := e.createUniFiClient(apiConfig)

	headers := map[string]string{
		"X-API-Key":    apiConfig.APIKey,
		"Content-Type": "application/json",
	}

	sitesURL := fmt.Sprintf("%s/sites", apiConfig.BaseURL)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sitesURL, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create sites request for %s: %w", apiConfig.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch sites from %s: %w", apiConfig.Name, err)
	}
	defer func() {
		_ = resp.Body.Close() // Ignore close error in defer
	}()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w for %s with status: %d", ErrUniFiSitesRequestFailed, apiConfig.Name, resp.StatusCode)
	}

	var sitesResp struct {
		Data []UniFiSite `json:"data"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&sitesResp); err != nil {
		return nil, fmt.Errorf("failed to parse sites response from %s: %w", apiConfig.Name, err)
	}

	if len(sitesResp.Data) == 0 {
		return nil, fmt.Errorf("%w for %s", ErrNoUniFiSitesFound, apiConfig.Name)
	}

	// Cache sites
	job.mu.Lock()

	if job.uniFiSiteCache == nil {
		job.uniFiSiteCache = make(map[string][]UniFiSite)
	}

	job.uniFiSiteCache[apiConfig.BaseURL] = sitesResp.Data
	job.mu.Unlock()

	return sitesResp.Data, nil
}

func (e *DiscoveryEngine) queryUniFiAPI(
	ctx context.Context, job *DiscoveryJob, targetIP string) ([]*TopologyLink, error) {
	e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).Msg("Querying UniFi APIs")

	var allLinks []*TopologyLink

	seenLinks := make(map[string]struct{})
	selectedAPIs := e.unifiAPIsForJob(job)

	for _, apiConfig := range selectedAPIs {
		if apiConfig.BaseURL == "" || apiConfig.APIKey == "" {
			e.logger.Warn().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
				Msg("Skipping incomplete UniFi API config")

			continue
		}

		sites, err := e.fetchUniFiSites(ctx, job, apiConfig)
		if err != nil {
			e.logger.Error().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Err(err).
				Msg("Failed to fetch sites")

			continue
		}

		for _, site := range sites {
			links, err := e.querySingleUniFiAPI(ctx, job, targetIP, apiConfig, site)
			if err != nil {
				e.logger.Error().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
					Str("site_name", site.Name).Err(err).Msg("Failed to query UniFi API")

				continue
			}

			for _, link := range links {
				linkKey := uniFiLinkDedupKey(link, site.ID)
				if _, exists := seenLinks[linkKey]; !exists {
					seenLinks[linkKey] = struct{}{}

					allLinks = append(allLinks, link)
				}
			}
		}
	}

	if len(allLinks) == 0 {
		return nil, ErrNoUniFiNeighborsFound
	}

	return allLinks, nil
}

func (e *DiscoveryEngine) querySingleUniFiAPI(
	ctx context.Context,
	job *DiscoveryJob,
	targetIP string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]*TopologyLink, error) {
	client := e.createUniFiClient(apiConfig)
	headers := map[string]string{
		"X-API-Key":    apiConfig.APIKey,
		"Content-Type": "application/json",
	}

	// Fetch devices and create device cache
	devices, deviceCache, err :=
		e.fetchUniFiDevicesForSite(ctx, job, client, headers, apiConfig, site)
	if err != nil {
		return nil, err
	}

	siteClients, err := e.fetchUniFiClientsForSite(ctx, client, headers, apiConfig, site)
	if err != nil {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("api_name", apiConfig.Name).
			Str("site_name", site.Name).
			Err(err).
			Msg("Failed to fetch UniFi client associations; continuing without client topology")
		siteClients = nil
	}

	var wirelessClients, wiredClients []UniFiClient
	for i := range siteClients {
		switch siteClients[i].normalizedType() {
		case "WIRELESS":
			wirelessClients = append(wirelessClients, siteClients[i])
		case "WIRED":
			wiredClients = append(wiredClients, siteClients[i])
		}
	}

	var links []*TopologyLink
	lldpCount := 0
	portCount := 0
	uplinkCount := 0
	wirelessClientCount := 0
	wiredClientCount := 0
	var legacyDetails []legacyUniFiDeviceDetailsRecord
	legacyDetailsLoaded := false
	if targetIP != "" {
		e.logger.Debug().
			Str("job_id", job.ID).
			Str("target_ip", targetIP).
			Str("api_name", apiConfig.Name).
			Str("site_name", site.Name).
			Msg("Building UniFi topology from full site inventory")
	}

	// Process each device
	for i := range devices {
		device := &devices[i]

		deviceID := GenerateDeviceID(device.MAC)

		// Fetch device details
		details, err := e.fetchDeviceDetails(ctx, job, client, headers, apiConfig, site, device.ID)
		if err != nil {
			if errors.Is(err, ErrUniFiPayloadDriftQuarantined) {
				e.logger.Warn().
					Str("job_id", job.ID).
					Str("api_name", apiConfig.Name).
					Str("site_name", site.Name).
					Str("device_id", device.ID).
					Err(err).
					Msg("Falling back to site inventory uplink data after quarantined UniFi detail payload")

				if !legacyDetailsLoaded {
					legacyDetails, err = e.fetchLegacyUniFiDeviceDetailsForSite(
						ctx,
						client,
						headers,
						apiConfig,
						site,
					)
					legacyDetailsLoaded = true
					if err != nil {
						e.logger.Warn().
							Str("job_id", job.ID).
							Str("api_name", apiConfig.Name).
							Str("site_name", site.Name).
							Err(err).
							Msg("Failed to load legacy UniFi device stats fallback")
					}
				}

				if details == nil && len(legacyDetails) > 0 {
					details = matchLegacyUniFiDeviceDetails(device, legacyDetails)
					if details != nil {
						e.logger.Info().
							Str("job_id", job.ID).
							Str("api_name", apiConfig.Name).
							Str("site_name", site.Name).
							Str("device_id", device.ID).
							Str("adapter_version", details.AdapterVersion).
							Msg("Recovered UniFi topology signals from legacy stat/device fallback")
					}
				}
			} else {
				e.logger.Error().Str("job_id", job.ID).Err(err).Msg("UniFi device processing error")

				continue
			}
		}

		if details != nil {
			// Process LLDP table
			lldpLinks := e.processLLDPTable(job, device, deviceID, details, apiConfig, site)
			links = append(links, lldpLinks...)
			lldpCount += len(lldpLinks)

			// Process port table
			portLinks := e.processPortTable(job, device, deviceID, details, deviceCache, apiConfig, site)
			links = append(links, portLinks...)
			portCount += len(portLinks)
		}

		// Process uplink information
		uplinkLinks := e.processUplinkInfo(job, device, details, deviceCache, apiConfig, site)
		links = append(links, uplinkLinks...)
		uplinkCount += len(uplinkLinks)
	}

	wirelessLinks := e.processWirelessClientAssociations(job, wirelessClients, deviceCache, apiConfig, site)
	links = append(links, wirelessLinks...)
	wirelessClientCount = len(wirelessLinks)

	wiredLinks := e.processWiredClientAssociations(job, wiredClients, deviceCache, apiConfig, site)
	links = append(links, wiredLinks...)
	wiredClientCount = len(wiredLinks)

	e.logger.Info().
		Str("job_id", job.ID).
		Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).
		Int("devices", len(devices)).
		Int("lldp_links", lldpCount).
		Int("port_links", portCount).
		Int("uplink_links", uplinkCount).
		Int("wireless_client_links", wirelessClientCount).
		Int("wired_client_links", wiredClientCount).
		Int("total_links", len(links)).
		Msg("UniFi topology extraction summary")

	return links, nil
}
