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

package mtls

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

const tokenPrefix = "edgepkg-v1:"

// TokenPayload contains the decoded information from an edgepkg-v1 token.
type TokenPayload struct {
	PackageID     string `json:"pkg"`
	DownloadToken string `json:"dl"`
	CoreURL       string `json:"api,omitempty"`
}

// ParseToken parses an edgepkg-v1 token and returns its payload.
// The fallbackHost is used if the token doesn't contain a Core API URL.
func ParseToken(raw, fallbackHost string) (*TokenPayload, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, ErrTokenRequired
	}

	if !strings.HasPrefix(raw, tokenPrefix) {
		return nil, ErrUnsupportedTokenFormat
	}

	encoded := strings.TrimPrefix(raw, tokenPrefix)
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("decode token: %w", err)
	}

	var payload TokenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal token: %w", err)
	}

	if payload.PackageID == "" {
		return nil, ErrMissingPackageID
	}
	if strings.TrimSpace(payload.DownloadToken) == "" {
		return nil, ErrMissingDownloadToken
	}
	if payload.CoreURL == "" {
		payload.CoreURL = strings.TrimSpace(fallbackHost)
	}
	if payload.CoreURL == "" {
		return nil, ErrCoreAPIHostRequired
	}

	return &payload, nil
}
