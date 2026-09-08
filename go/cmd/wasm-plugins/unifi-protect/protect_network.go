package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func fetchUniFiNetworkClients(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	cfg Config,
	cameras []ProtectCamera,
) (map[string]UniFiNetworkClient, []EndpointResult) {
	needed := neededCameraMACsForNetworkLookup(cfg, cameras)
	if len(needed) == 0 {
		return nil, nil
	}

	sites, siteResult, err := fetchUniFiNetworkSites(ctx, client, headers)
	endpoints := []EndpointResult{siteResult}
	if err != nil || len(sites) == 0 {
		return nil, endpoints
	}

	matches := make(map[string]UniFiNetworkClient, len(needed))
	for _, site := range sites {
		siteMatches, siteEndpoints := fetchUniFiNetworkSiteClientMatches(ctx, client, headers, site.ID, needed)
		endpoints = append(endpoints, siteEndpoints...)
		for mac, networkClient := range siteMatches {
			existing, exists := matches[mac]
			if !exists || uniFiNetworkClientScore(networkClient) > uniFiNetworkClientScore(existing) {
				matches[mac] = networkClient
			}
		}
	}

	if len(matches) == 0 {
		return nil, endpoints
	}

	return matches, endpoints
}

func fetchUniFiNetworkSites(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
) ([]UniFiNetworkSite, EndpointResult, error) {
	path := "/proxy/network/integration/v1/sites"
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return nil, EndpointResult{Path: path, Error: err.Error()}, err
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("network sites request failed with status %d", resp.Status)
		return nil, trimBody(result), fmt.Errorf("%s", result.Error)
	}

	var payload uniFiNetworkSitesResponse
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid network sites payload: " + err.Error()
		return nil, trimBody(result), err
	}

	return payload.Data, trimBody(result), nil
}

func fetchUniFiNetworkSiteClientMatches(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	siteID string,
	needed map[string]struct{},
) (map[string]UniFiNetworkClient, []EndpointResult) {
	const limit = 200

	matches := make(map[string]UniFiNetworkClient, len(needed))
	endpoints := make([]EndpointResult, 0, 4)

	for offset := 0; ; offset += limit {
		page, pageResult, err := fetchUniFiNetworkClientPage(ctx, client, headers, siteID, offset, limit)
		endpoints = append(endpoints, pageResult)
		if err != nil {
			return matches, endpoints
		}

		for _, summary := range page.Data {
			mac := normalizeMACKey(firstNonEmpty(summary.MACAddress, summary.MAC))
			if mac == "" {
				continue
			}
			if _, wanted := needed[mac]; !wanted {
				continue
			}

			networkClient := summary
			if uniFiNetworkClientInventoryHost(networkClient) == "" && strings.TrimSpace(networkClient.ID) != "" {
				detail, detailResult, detailErr := fetchUniFiNetworkClientDetail(ctx, client, headers, siteID, networkClient.ID)
				endpoints = append(endpoints, detailResult)
				if detailErr == nil {
					networkClient = mergeUniFiNetworkClient(summary, detail)
				}
			}

			existing, exists := matches[mac]
			if !exists || uniFiNetworkClientScore(networkClient) > uniFiNetworkClientScore(existing) {
				matches[mac] = networkClient
			}
		}

		if len(page.Data) == 0 || len(page.Data) < limit || offset+len(page.Data) >= page.TotalCount {
			break
		}
	}

	return matches, endpoints
}

func fetchUniFiNetworkClientPage(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	siteID string,
	offset int,
	limit int,
) (uniFiNetworkClientsResponse, EndpointResult, error) {
	path := fmt.Sprintf(
		"/proxy/network/integration/v1/sites/%s/clients?offset=%d&limit=%d",
		url.PathEscape(strings.TrimSpace(siteID)),
		offset,
		limit,
	)
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return uniFiNetworkClientsResponse{}, EndpointResult{Path: path, Error: err.Error()}, err
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("network clients request failed with status %d", resp.Status)
		return uniFiNetworkClientsResponse{}, trimBody(result), fmt.Errorf("%s", result.Error)
	}

	var payload uniFiNetworkClientsResponse
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid network clients payload: " + err.Error()
		return uniFiNetworkClientsResponse{}, trimBody(result), err
	}

	return payload, trimBody(result), nil
}

func fetchUniFiNetworkClientDetail(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	siteID string,
	clientID string,
) (UniFiNetworkClient, EndpointResult, error) {
	path := fmt.Sprintf(
		"/proxy/network/integration/v1/sites/%s/clients/%s",
		url.PathEscape(strings.TrimSpace(siteID)),
		url.PathEscape(strings.TrimSpace(clientID)),
	)
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return UniFiNetworkClient{}, EndpointResult{Path: path, Error: err.Error()}, err
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("network client detail request failed with status %d", resp.Status)
		return UniFiNetworkClient{}, trimBody(result), fmt.Errorf("%s", result.Error)
	}

	var payload UniFiNetworkClient
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid network client detail payload: " + err.Error()
		return UniFiNetworkClient{}, trimBody(result), err
	}

	return payload, trimBody(result), nil
}

func neededCameraMACsForNetworkLookup(cfg Config, cameras []ProtectCamera) map[string]struct{} {
	needed := make(map[string]struct{})
	for _, camera := range cameras {
		if protectCameraInventoryHost(cfg, camera) != "" {
			continue
		}
		mac := normalizeMACKey(camera.MAC)
		if mac == "" {
			continue
		}
		needed[mac] = struct{}{}
	}
	return needed
}

func mergeUniFiNetworkClient(summary, detail UniFiNetworkClient) UniFiNetworkClient {
	return UniFiNetworkClient{
		ID:          firstNonEmpty(detail.ID, summary.ID),
		MACAddress:  firstNonEmpty(detail.MACAddress, summary.MACAddress),
		MAC:         firstNonEmpty(detail.MAC, summary.MAC),
		IPAddress:   firstNonEmpty(detail.IPAddress, summary.IPAddress),
		IP:          firstNonEmpty(detail.IP, summary.IP),
		Hostname:    firstNonEmpty(detail.Hostname, summary.Hostname),
		Name:        firstNonEmpty(detail.Name, summary.Name),
		DisplayName: firstNonEmpty(detail.DisplayName, summary.DisplayName),
	}
}

func uniFiNetworkClientInventoryHost(networkClient UniFiNetworkClient) string {
	return firstNonEmpty(networkClient.IPAddress, networkClient.IP)
}

func uniFiNetworkClientScore(networkClient UniFiNetworkClient) int {
	score := 0
	if uniFiNetworkClientInventoryHost(networkClient) != "" {
		score += 10
	}
	if firstNonEmpty(networkClient.Hostname, networkClient.Name, networkClient.DisplayName) != "" {
		score++
	}
	return score
}
