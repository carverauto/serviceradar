package edgeonboarding

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

const (
	tokenV1Prefix                = "edgepkg-v1:"
	tokenV2Prefix                = "edgepkg-v2:"
	onboardingTokenPrivateKeyEnv = "SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY"
	onboardingTokenPublicKeyEnv  = "SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY"
	onboardingTokenSignatureSep  = "."
)

var (
	ErrOnboardingTokenPrivateKeyRequired = errors.New("onboarding token private key is not configured")
	ErrOnboardingTokenPublicKeyRequired  = errors.New("onboarding token public key is not configured")
	ErrOnboardingTokenInvalidSignature   = errors.New("onboarding token signature is invalid")
	ErrOnboardingTokenMalformed          = errors.New("onboarding token is malformed")
)

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

	if strings.HasPrefix(raw, tokenV2Prefix) {
		return parseSignedStructuredToken(raw, fallbackPackageID, fallbackCoreURL)
	}

	if strings.HasPrefix(raw, tokenV1Prefix) {
		return parseStructuredToken(raw, fallbackPackageID, fallbackCoreURL)
	}

	return parseLegacyToken(raw, fallbackPackageID, fallbackCoreURL)
}

func parseStructuredToken(raw string, fallbackPackageID, fallbackCoreURL string) (*tokenPayload, error) {
	encoded := strings.TrimPrefix(raw, tokenV1Prefix)
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
	// Legacy unsigned tokens must not be allowed to redirect enrollment to an
	// arbitrary origin. Only a separately trusted CLI/core-url fallback is used.
	payload.CoreURL = strings.TrimSpace(fallbackCoreURL)

	if err := validateTokenPayload(&payload); err != nil {
		return nil, err
	}

	return &payload, nil
}

func parseSignedStructuredToken(raw string, fallbackPackageID, fallbackCoreURL string) (*tokenPayload, error) {
	encoded := strings.TrimPrefix(raw, tokenV2Prefix)
	encodedPayload, encodedSignature, ok := strings.Cut(encoded, onboardingTokenSignatureSep)
	if !ok || encodedPayload == "" || encodedSignature == "" {
		return nil, ErrOnboardingTokenMalformed
	}

	data, err := base64.RawURLEncoding.DecodeString(encodedPayload)
	if err != nil {
		return nil, fmt.Errorf("decode onboarding token payload: %w", err)
	}

	signature, err := base64.RawURLEncoding.DecodeString(encodedSignature)
	if err != nil {
		return nil, fmt.Errorf("decode onboarding token signature: %w", err)
	}

	publicKey, err := onboardingTokenPublicKey()
	if err != nil {
		return nil, err
	}

	if !ed25519.Verify(publicKey, data, signature) {
		return nil, ErrOnboardingTokenInvalidSignature
	}

	var payload tokenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal onboarding token: %w", err)
	}

	if payload.PackageID == "" {
		payload.PackageID = fallbackPackageID
	}
	if strings.TrimSpace(payload.CoreURL) == "" {
		payload.CoreURL = strings.TrimSpace(fallbackCoreURL)
	}

	if err := validateTokenPayload(&payload); err != nil {
		return nil, err
	}

	return &payload, nil
}

func parseLegacyToken(raw string, fallbackPackageID, fallbackCoreURL string) (*tokenPayload, error) {
	payload := &tokenPayload{
		PackageID: fallbackPackageID,
		CoreURL:   strings.TrimSpace(fallbackCoreURL),
	}
	legacy := raw

	if at := strings.Index(legacy, "@"); at > 0 {
		maybeURL := strings.TrimSpace(legacy[:at])
		remainder := strings.TrimSpace(legacy[at+1:])
		if looksLikeURL(maybeURL) && remainder != "" {
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
	return tokenV1Prefix + base64.RawURLEncoding.EncodeToString(buf), nil
}

func encodeSignedTokenPayload(payload tokenPayload) (string, error) {
	if err := validateTokenPayload(&payload); err != nil {
		return "", err
	}

	buf, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	privateKey, err := onboardingTokenPrivateKey()
	if err != nil {
		return "", err
	}

	signature := ed25519.Sign(privateKey, buf)
	return tokenV2Prefix +
		base64.RawURLEncoding.EncodeToString(buf) +
		onboardingTokenSignatureSep +
		base64.RawURLEncoding.EncodeToString(signature), nil
}

func onboardingTokenPrivateKey() (ed25519.PrivateKey, error) {
	raw := strings.TrimSpace(os.Getenv(onboardingTokenPrivateKeyEnv))
	if raw == "" {
		return nil, ErrOnboardingTokenPrivateKeyRequired
	}

	keyBytes, err := decodeOnboardingTokenKey(raw)
	if err != nil {
		return nil, fmt.Errorf("decode onboarding token private key: %w", err)
	}

	switch len(keyBytes) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(keyBytes), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(keyBytes), nil
	default:
		return nil, fmt.Errorf("invalid onboarding token private key length: %d", len(keyBytes))
	}
}

func onboardingTokenPublicKey() (ed25519.PublicKey, error) {
	raw := strings.TrimSpace(os.Getenv(onboardingTokenPublicKeyEnv))
	if raw == "" {
		return nil, ErrOnboardingTokenPublicKeyRequired
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

	return nil, ErrOnboardingTokenMalformed
}

// EncodeToken builds a signed edgepkg-v2 token that embeds the package id,
// download token, and optional Core API base URL so bootstrap clients only need
// ONBOARDING_TOKEN plus the configured public verification key.
func EncodeToken(packageID, downloadToken, coreAPIURL string) (string, error) {
	payload := tokenPayload{
		PackageID:     strings.TrimSpace(packageID),
		DownloadToken: strings.TrimSpace(downloadToken),
	}
	if trimmed := strings.TrimSpace(coreAPIURL); trimmed != "" {
		payload.CoreURL = trimmed
	}
	return encodeSignedTokenPayload(payload)
}

// IsStructuredToken reports whether the token uses the structured edge package format.
func IsStructuredToken(raw string) bool {
	raw = strings.TrimSpace(raw)
	return strings.HasPrefix(raw, tokenV1Prefix) || strings.HasPrefix(raw, tokenV2Prefix)
}
