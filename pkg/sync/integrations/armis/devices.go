package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
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
	searchQuery := "in:devices orderBy=id"

	// Add boundary filter if specified
	if a.BoundaryName != "" {
		searchQuery += fmt.Sprintf(` boundaries:%q`, a.BoundaryName)
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
		return nil, errSearchRequestFailed
	}

	return &searchResp, nil
}

// processDevices converts devices to KV data and extracts IPs.
func (*ArmisIntegration) processDevices(devices []Device) (data map[string][]byte, ips []string) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(devices))

	for i := range devices {
		device := &devices[i] // Use a pointer to avoid copying the struct

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
