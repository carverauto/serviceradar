package edgeonboarding

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

const tokenPrefix = "edgepkg-v1:"

type tokenPayload struct {
	PackageID     string `json:"pkg"`
	DownloadToken string `json:"dl"`
	CoreURL       string `json:"api,omitempty"`
}

func parseOnboardingToken(raw string, fallbackPackageID, fallbackCoreURL string) (*tokenPayload, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, ErrTokenRequired
	}

	if strings.HasPrefix(raw, tokenPrefix) {
		return parseStructuredToken(raw, fallbackPackageID, fallbackCoreURL)
	}

	return parseLegacyToken(raw, fallbackPackageID, fallbackCoreURL)
}

func parseStructuredToken(raw string, fallbackPackageID, fallbackCoreURL string) (*tokenPayload, error) {
	encoded := strings.TrimPrefix(raw, tokenPrefix)
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("decode onboarding token: %w", err)
	}

	var payload tokenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal onboarding token: %w", err)
	}

	if payload.PackageID == "" {
		payload.PackageID = fallbackPackageID
	}
	if payload.CoreURL == "" {
		payload.CoreURL = fallbackCoreURL
	}

	if err := validateTokenPayload(&payload); err != nil {
		return nil, err
	}

	return &payload, nil
}

func parseLegacyToken(raw string, fallbackPackageID, fallbackCoreURL string) (*tokenPayload, error) {
	payload := &tokenPayload{
		PackageID: fallbackPackageID,
		CoreURL:   fallbackCoreURL,
	}
	legacy := raw

	if at := strings.Index(legacy, "@"); at > 0 {
		maybeURL := strings.TrimSpace(legacy[:at])
		remainder := strings.TrimSpace(legacy[at+1:])
		if looksLikeURL(maybeURL) && remainder != "" {
			payload.CoreURL = maybeURL
			legacy = remainder
		}
	}

	for _, sep := range []string{":", "/", "|", ","} {
		if idx := strings.Index(legacy, sep); idx != -1 {
			payload.PackageID = strings.TrimSpace(legacy[:idx])
			payload.DownloadToken = strings.TrimSpace(legacy[idx+1:])
			return ensureLegacyDefaults(payload)
		}
	}

	payload.DownloadToken = strings.TrimSpace(legacy)
	return ensureLegacyDefaults(payload)
}

func ensureLegacyDefaults(payload *tokenPayload) (*tokenPayload, error) {
	if err := validateTokenPayload(payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func validateTokenPayload(payload *tokenPayload) error {
	if payload.PackageID == "" {
		return ErrPackageIDEmpty
	}
	if strings.TrimSpace(payload.DownloadToken) == "" {
		return ErrDownloadTokenEmpty
	}
	payload.DownloadToken = strings.TrimSpace(payload.DownloadToken)
	return nil
}

func looksLikeURL(raw string) bool {
	raw = strings.ToLower(strings.TrimSpace(raw))
	return strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://")
}

func encodeTokenPayload(payload tokenPayload) (string, error) {
	if err := validateTokenPayload(&payload); err != nil {
		return "", err
	}
	buf, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(buf), nil
}

// EncodeToken builds an edgepkg-v1 token that embeds the package id, download token,
// and optional Core API base URL so bootstrap clients only need ONBOARDING_TOKEN.
func EncodeToken(packageID, downloadToken, coreAPIURL string) (string, error) {
	payload := tokenPayload{
		PackageID:     strings.TrimSpace(packageID),
		DownloadToken: strings.TrimSpace(downloadToken),
	}
	if trimmed := strings.TrimSpace(coreAPIURL); trimmed != "" {
		payload.CoreURL = trimmed
	}
	return encodeTokenPayload(payload)
}
