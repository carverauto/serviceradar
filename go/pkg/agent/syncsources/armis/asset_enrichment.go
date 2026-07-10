/*
 * Copyright 2026 Carver Automation Corporation.
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

package armis

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	defaultV3Endpoint = "https://api.armis.com"
	v3OAuthTokenPath  = "/v3/oauth/token"
	v3AssetSearchPath = "/v3/assets/_search"
)

var (
	errV3TokenRequestFailed      = errors.New("armis v3 token request failed")
	errV3TokenMissingAccessToken = errors.New("armis v3 token response missing access_token")
	errV3AssetSearchFailed       = errors.New("armis v3 asset search failed")
	errV3CredentialsMissing      = errors.New("armis v3 asset enrichment requires credentials")
)

func defaultV3Scopes() []string {
	return []string{
		"PERMISSION.DEVICE.READ",
		"PERMISSION.PII.DEVICE",
		"FULL_VISIBILITY",
	}
}

type assetEnrichmentConfig struct {
	fields   []string
	endpoint string
	audience string
	scopes   []string
}

type v3TokenResponse struct {
	AccessToken string `json:"access_token"`
	Token       string `json:"token"`
	Data        struct {
		AccessToken string `json:"access_token"`
		Token       string `json:"token"`
	} `json:"data"`
}

type v3AssetSearchResponse struct {
	Items []struct {
		AssetID any                        `json:"asset_id"`
		Fields  map[string]json.RawMessage `json:"fields"`
	} `json:"items"`
	Next any `json:"next"`
}

func newAssetEnrichmentConfig(source models.SourceConfig) assetEnrichmentConfig {
	fields := configuredAssetFields(source)
	if len(fields) == 0 {
		return assetEnrichmentConfig{}
	}

	endpoint := strings.TrimRight(firstStringSetting(source.Settings, "v3_endpoint", "armis_v3_endpoint"), "/")
	if endpoint == "" {
		endpoint = defaultV3Endpoint
	}

	audience := firstCredentialValue(source.Credentials, "v3_audience", "audience")
	if audience == "" {
		audience = strings.TrimRight(source.Endpoint, "/") + "/"
	}

	scopes := stringListSetting(source.Settings, "v3_scopes", "armis_v3_scopes")
	if len(scopes) == 0 {
		scopes = defaultV3Scopes()
	}

	return assetEnrichmentConfig{
		fields:   fields,
		endpoint: endpoint,
		audience: audience,
		scopes:   scopes,
	}
}

func (c *client) v3AccessToken(ctx context.Context, source models.SourceConfig, cfg assetEnrichmentConfig) (string, error) {
	clientID := firstCredentialValue(source.Credentials, "v3_client_id", "client_id")
	clientSecret := firstCredentialValue(source.Credentials, "v3_client_secret", "client_secret")
	vendorID := firstCredentialValue(source.Credentials, "v3_vendor_id", "vendor_id")

	missing := missingV3CredentialNames(clientID, clientSecret, vendorID)
	if len(missing) > 0 {
		return "", fmt.Errorf("%w: %s", errV3CredentialsMissing, strings.Join(missing, ", "))
	}

	endpoint, err := resolveURLForBase(cfg.endpoint, v3OAuthTokenPath)
	if err != nil {
		return "", err
	}

	payload := map[string]any{
		"audience":      cfg.audience,
		"grant_type":    "client_credentials",
		"client_id":     clientID,
		"client_secret": clientSecret,
		"vendor_id":     vendorID,
		"scopes":        cfg.scopes,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if len(body) > 0 {
			return "", fmt.Errorf("%w: %s: %s", errV3TokenRequestFailed, resp.Status, strings.TrimSpace(string(body)))
		}

		return "", fmt.Errorf("%w: %s", errV3TokenRequestFailed, resp.Status)
	}

	var token v3TokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&token); err != nil {
		return "", err
	}

	if accessToken := token.accessToken(); accessToken != "" {
		return accessToken, nil
	}

	return "", errV3TokenMissingAccessToken
}

func missingV3CredentialNames(clientID string, clientSecret string, vendorID string) []string {
	var missing []string
	if clientID == "" {
		missing = append(missing, "client_id")
	}
	if clientSecret == "" {
		missing = append(missing, "client_secret")
	}
	if vendorID == "" {
		missing = append(missing, "vendor_id")
	}

	return missing
}

func (r v3TokenResponse) accessToken() string {
	for _, value := range []string{
		r.AccessToken,
		r.Token,
		r.Data.AccessToken,
		r.Data.Token,
	} {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}

	return ""
}

func (c *client) enrichAssetFields(
	ctx context.Context,
	token string,
	cfg assetEnrichmentConfig,
	devices []device,
) ([]device, error) {
	if len(cfg.fields) == 0 || len(devices) == 0 {
		return devices, nil
	}

	assetIDs, indexesByAssetID := assetIDsForDevices(devices)
	if len(assetIDs) == 0 {
		return devices, nil
	}

	var after any
	seenAfter := map[string]struct{}{}

	for {
		resp, err := c.v3AssetSearch(ctx, token, cfg, assetIDs, after)
		if err != nil {
			return nil, err
		}

		for _, item := range resp.Items {
			assetID := assetIDKey(item.AssetID)
			indexes := indexesByAssetID[assetID]
			if len(indexes) == 0 {
				continue
			}

			for field, raw := range item.Fields {
				for _, index := range indexes {
					devices[index].setRawField(field, raw)
				}
			}
		}

		next, ok := nextSearchOffset(resp.Next)
		if !ok {
			break
		}

		nextKey := fmt.Sprint(next)
		if _, seen := seenAfter[nextKey]; seen {
			break
		}
		seenAfter[nextKey] = struct{}{}
		after = next
	}

	return devices, nil
}

func (c *client) v3AssetSearch(
	ctx context.Context,
	token string,
	cfg assetEnrichmentConfig,
	assetIDs []any,
	after any,
) (*v3AssetSearchResponse, error) {
	endpoint, err := resolveURLForBase(cfg.endpoint, v3AssetSearchPath)
	if err != nil {
		return nil, err
	}

	filter := map[string]any{
		"filter_criteria": "ASSET_ID",
		"asset_id_source": "ASSET_ID",
		"asset_ids":       assetIDs,
		"limit":           len(assetIDs),
	}
	if after != nil {
		filter["after"] = after
	}

	payload := map[string]any{
		"asset_type": "DEVICE",
		"fields":     cfg.fields,
		"filter":     filter,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, &requestError{
			err:        errV3AssetSearchFailed,
			statusCode: resp.StatusCode,
			status:     resp.Status,
			body:       strings.TrimSpace(string(body)),
		}
	}

	var result v3AssetSearchResponse
	decoder := json.NewDecoder(resp.Body)
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return nil, err
	}

	return &result, nil
}

func assetIDsForDevices(devices []device) ([]any, map[string][]int) {
	assetIDs := make([]any, 0, len(devices))
	indexesByAssetID := make(map[string][]int, len(devices))

	for index, item := range devices {
		id := item.effectiveID()
		if id <= 0 {
			continue
		}

		key := strconv.Itoa(id)
		if _, exists := indexesByAssetID[key]; !exists {
			assetIDs = append(assetIDs, id)
		}
		indexesByAssetID[key] = append(indexesByAssetID[key], index)
	}

	return assetIDs, indexesByAssetID
}

func assetIDKey(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case json.Number:
		return typed.String()
	case float64:
		if typed == float64(int64(typed)) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case string:
		return strings.TrimSpace(typed)
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func nextSearchOffset(value any) (any, bool) {
	switch typed := value.(type) {
	case nil:
		return nil, false
	case json.Number:
		if typed.String() == "" || typed.String() == "0" {
			return nil, false
		}
		return typed, true
	case float64:
		if typed <= 0 {
			return nil, false
		}
		return typed, true
	case string:
		typed = strings.TrimSpace(typed)
		if typed == "" || typed == "0" {
			return nil, false
		}
		return typed, true
	default:
		return typed, true
	}
}

func firstStringSetting(settings map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := settingValue(settings, key)
		if !ok {
			continue
		}

		if stringValue := strings.TrimSpace(toStringValue(value)); stringValue != "" {
			return stringValue
		}
	}

	return ""
}

func resolveURLForBase(base string, path string) (string, error) {
	parsedBase, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		return "", err
	}

	ref, err := url.Parse(path)
	if err != nil {
		return "", err
	}

	return parsedBase.ResolveReference(ref).String(), nil
}
