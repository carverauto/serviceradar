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
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

const (
	tokenV2Prefix               = "edgepkg-v2:"
	onboardingTokenPublicKeyEnv = "SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY"
	onboardingTokenSignatureSep = "."
)

// TokenPayload contains the decoded information from an edge onboarding token.
type TokenPayload struct {
	PackageID     string `json:"pkg"`
	DownloadToken string `json:"dl"`
	CoreURL       string `json:"api,omitempty"`
}

// ParseToken parses a signed edge onboarding token and returns its payload.
func ParseToken(raw, fallbackHost string) (*TokenPayload, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, ErrTokenRequired
	}

	if !strings.HasPrefix(raw, tokenV2Prefix) {
		return nil, ErrUnsupportedTokenFormat
	}

	return parseSignedToken(raw, fallbackHost)
}

func parseSignedToken(raw, fallbackHost string) (*TokenPayload, error) {
	encoded := strings.TrimPrefix(raw, tokenV2Prefix)
	encodedPayload, encodedSignature, ok := strings.Cut(encoded, onboardingTokenSignatureSep)
	if !ok || encodedPayload == "" || encodedSignature == "" {
		return nil, ErrMalformedToken
	}

	data, err := base64.RawURLEncoding.DecodeString(encodedPayload)
	if err != nil {
		return nil, fmt.Errorf("decode token payload: %w", err)
	}

	signature, err := base64.RawURLEncoding.DecodeString(encodedSignature)
	if err != nil {
		return nil, fmt.Errorf("decode token signature: %w", err)
	}

	publicKey, err := onboardingTokenPublicKey()
	if err != nil {
		return nil, err
	}

	if !ed25519.Verify(publicKey, data, signature) {
		return nil, ErrInvalidTokenSignature
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
	if strings.TrimSpace(payload.CoreURL) == "" {
		payload.CoreURL = strings.TrimSpace(fallbackHost)
	}
	if payload.CoreURL == "" {
		return nil, ErrCoreAPIHostRequired
	}

	return &payload, nil
}

func onboardingTokenPublicKey() (ed25519.PublicKey, error) {
	raw := strings.TrimSpace(os.Getenv(onboardingTokenPublicKeyEnv))
	if raw == "" {
		return nil, ErrTokenPublicKeyRequired
	}

	keyBytes, err := decodeOnboardingTokenKey(raw)
	if err != nil {
		return nil, fmt.Errorf("decode onboarding token public key: %w", err)
	}
	if len(keyBytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid onboarding token public key length: %d", len(keyBytes))
	}

	return ed25519.PublicKey(keyBytes), nil
}

func decodeOnboardingTokenKey(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	decodeFns := []func(string) ([]byte, error){
		base64.StdEncoding.DecodeString,
		base64.RawStdEncoding.DecodeString,
		base64.URLEncoding.DecodeString,
		base64.RawURLEncoding.DecodeString,
		hex.DecodeString,
	}

	for _, decodeFn := range decodeFns {
		if decoded, err := decodeFn(raw); err == nil {
			return decoded, nil
		}
	}

	return nil, ErrMalformedToken
}
