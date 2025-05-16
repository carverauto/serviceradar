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

// Package armis pkg/sync/integrations/armis.go provides an integration with the Armis API.
package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// GetAccessToken obtains a temporary access token from Armis.
func (d *DefaultArmisIntegration) GetAccessToken(ctx context.Context) (string, error) {
	// Form data must be application/x-www-form-urlencoded
	data := url.Values{}
	data.Set("secret_key", d.Config.Credentials["secret_key"])

	// Create the request
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/v1/access_token/", d.Config.Endpoint),
		strings.NewReader(data.Encode()))
	if err != nil {
		return "", err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	// Send the request
	resp, err := d.HTTPClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	// Check response status
	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("%w: %d, response: %s", errUnexpectedStatusCode,
			resp.StatusCode, string(bodyBytes))
	}

	// Parse response
	var tokenResp AccessTokenResponse

	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return "", err
	}

	// Check success status
	if !tokenResp.Success {
		return "", errAuthFailed
	}

	return tokenResp.Data.AccessToken, nil
}
