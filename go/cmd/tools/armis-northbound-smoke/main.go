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

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultPageSize = 1000
	defaultMaxPages = 50
)

var (
	errRequiredEnvMissing              = errors.New("missing required env")
	errInvalidNorthboundValue          = errors.New("invalid northbound value")
	errTokenRequestFailed              = errors.New("token request failed")
	errTokenResponseMissingAccessToken = errors.New("token response missing data.access_token")
	errArmisDeviceNotFound             = errors.New("armis device not found")
	errSearchRequestFailed             = errors.New("search request failed")
	errBulkUpdateFailed                = errors.New("bulk update failed")
	errPositiveIntegerRequired         = errors.New("positive integer required")
)

type accessTokenResponse struct {
	Data struct {
		AccessToken string `json:"access_token"`
	} `json:"data"`
	Success bool `json:"success"`
}

type searchResponse struct {
	Data struct {
		Next    int           `json:"next"`
		Results []armisDevice `json:"results"`
	} `json:"data"`
	Success bool `json:"success"`
}

type armisDevice struct {
	ID        int    `json:"id"`
	IPAddress string `json:"ipAddress"`
	Name      string `json:"name"`
}

type bulkOperation struct {
	Upsert struct {
		DeviceID int    `json:"deviceId"`
		Key      string `json:"key"`
		Value    string `json:"value"`
	} `json:"upsert"`
}

func main() {
	if err := run(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "armis northbound smoke failed: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	endpoint, err := requiredEnv("SERVICERADAR_ARMIS_API_URL")
	if err != nil {
		return err
	}

	secret, err := requiredEnv("SERVICERADAR_ARMIS_API_SECRET")
	if err != nil {
		return err
	}

	deviceIP, err := requiredEnv("SERVICERADAR_ARMIS_DEVICE_IP")
	if err != nil {
		return err
	}

	customField, err := requiredEnv("SERVICERADAR_ARMIS_CUSTOM_FIELD")
	if err != nil {
		return err
	}

	northboundValue, err := northboundValue()
	if err != nil {
		return err
	}

	client := &http.Client{Timeout: 60 * time.Second}

	fmt.Printf("Fetching Armis access token from %s\n", strings.TrimRight(endpoint, "/"))

	token, err := fetchAccessToken(ctx, client, endpoint, secret)
	if err != nil {
		return err
	}

	fmt.Printf("Searching Armis for device IP %s\n", deviceIP)

	device, err := findDeviceByIP(ctx, client, endpoint, token, deviceIP)
	if err != nil {
		return err
	}

	fmt.Printf("Found Armis device id=%d name=%q ipAddress=%q\n", device.ID, device.Name, device.IPAddress)
	fmt.Printf("Sending northbound custom property update: %s=%s\n", customField, northboundValue)

	if err := sendBulkUpdate(ctx, client, endpoint, token, device.ID, customField, northboundValue); err != nil {
		return err
	}

	fmt.Printf("Armis northbound smoke succeeded: updated device_id=%d field=%s value=%s\n", device.ID, customField, northboundValue)

	return nil
}

func requiredEnv(name string) (string, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value != "" {
		return value, nil
	}

	return "", fmt.Errorf("%w: %s", errRequiredEnvMissing, name)
}

func northboundValue() (string, error) {
	value := strings.ToLower(strings.TrimSpace(os.Getenv("SERVICERADAR_ARMIS_NORTHBOUND_VALUE")))
	if value == "" {
		return "false", nil
	}

	if value != "true" && value != "false" {
		return "", fmt.Errorf(
			"%w: SERVICERADAR_ARMIS_NORTHBOUND_VALUE must be true or false, got %q",
			errInvalidNorthboundValue,
			value,
		)
	}

	return value, nil
}

func fetchAccessToken(ctx context.Context, client *http.Client, endpoint, secret string) (string, error) {
	form := url.Values{}
	form.Set("secret_key", secret)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpointURL(endpoint, "/api/v1/access_token/"), strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return "", fmt.Errorf("%w: HTTP %d: %s", errTokenRequestFailed, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var parsed accessTokenResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", fmt.Errorf("decode token response: %w", err)
	}

	if strings.TrimSpace(parsed.Data.AccessToken) == "" {
		return "", errTokenResponseMissingAccessToken
	}

	return parsed.Data.AccessToken, nil
}

func findDeviceByIP(ctx context.Context, client *http.Client, endpoint, token, deviceIP string) (*armisDevice, error) {
	aql := strings.TrimSpace(os.Getenv("SERVICERADAR_ARMIS_SEARCH_AQL"))
	if aql == "" {
		aql = "in:devices"
	}

	maxPages, err := positiveIntEnv("SERVICERADAR_ARMIS_SEARCH_MAX_PAGES", defaultMaxPages)
	if err != nil {
		return nil, err
	}

	for page := range maxPages {
		from := page * defaultPageSize

		resp, err := searchDevices(ctx, client, endpoint, token, aql, from, defaultPageSize)
		if err != nil {
			return nil, err
		}

		for i := range resp.Data.Results {
			if deviceMatchesIP(resp.Data.Results[i], deviceIP) {
				return &resp.Data.Results[i], nil
			}
		}

		if resp.Data.Next <= 0 {
			break
		}
	}

	return nil, fmt.Errorf(
		"%w: IP %s using AQL %q in %d scanned rows",
		errArmisDeviceNotFound,
		deviceIP,
		aql,
		maxPages*defaultPageSize,
	)
}

func searchDevices(ctx context.Context, client *http.Client, endpoint, token, aql string, from, length int) (*searchResponse, error) {
	parsed, err := url.Parse(endpointURL(endpoint, "/api/v1/search/"))
	if err != nil {
		return nil, err
	}

	params := parsed.Query()
	params.Set("aql", aql)
	params.Set("length", strconv.Itoa(length))
	if from > 0 {
		params.Set("from", strconv.Itoa(from))
	}
	parsed.RawQuery = params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", token)
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("%w: HTTP %d: %s", errSearchRequestFailed, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var parsedBody searchResponse
	if err := json.Unmarshal(body, &parsedBody); err != nil {
		return nil, fmt.Errorf("decode search response: %w", err)
	}

	return &parsedBody, nil
}

func sendBulkUpdate(ctx context.Context, client *http.Client, endpoint, token string, deviceID int, customField, value string) error {
	operation := bulkOperation{}
	operation.Upsert.DeviceID = deviceID
	operation.Upsert.Key = customField
	operation.Upsert.Value = value

	body, err := json.Marshal([]bulkOperation{operation})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		endpointURL(endpoint, "/api/v1/devices/custom-properties/_bulk/"),
		bytes.NewReader(body),
	)
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("%w: HTTP %d: %s", errBulkUpdateFailed, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	fmt.Printf("Bulk update accepted with HTTP %d: %s\n", resp.StatusCode, strings.TrimSpace(string(respBody)))

	return nil
}

func deviceMatchesIP(device armisDevice, expectedIP string) bool {
	for _, value := range strings.Split(device.IPAddress, ",") {
		if strings.TrimSpace(value) == expectedIP {
			return true
		}
	}

	return false
}

func endpointURL(endpoint, path string) string {
	return strings.TrimRight(endpoint, "/") + path
}

func positiveIntEnv(name string, defaultValue int) (int, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return defaultValue, nil
	}

	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%w: %s", errPositiveIntegerRequired, name)
	}

	return parsed, nil
}
