package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
)

const (
	releasePrivateKeyEnv     = "SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY"
	releasePrivateKeyFileEnv = "SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY_FILE"
)

var (
	errSigningKeyMissing = errors.New("agent release signing private key is not configured")
	errSigningKeyInvalid = errors.New("agent release signing private key is invalid")
)

func main() {
	privateKey, err := managedAgentReleasePrivateKey()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	fmt.Print(base64.StdEncoding.EncodeToString(privateKey.Public().(ed25519.PublicKey)))
}

func managedAgentReleasePrivateKey() (ed25519.PrivateKey, error) {
	keyValue := strings.TrimSpace(os.Getenv(releasePrivateKeyEnv))
	if keyValue == "" {
		keyFile := strings.TrimSpace(os.Getenv(releasePrivateKeyFileEnv))
		if keyFile != "" {
			content, err := os.ReadFile(keyFile)
			if err != nil {
				return nil, err
			}
			keyValue = strings.TrimSpace(string(content))
		}
	}
	if keyValue == "" {
		return nil, errSigningKeyMissing
	}

	keyBytes, err := decodeReleaseSigningValue(keyValue)
	if err != nil {
		return nil, err
	}

	switch len(keyBytes) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(keyBytes), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(keyBytes), nil
	default:
		return nil, fmt.Errorf("%w: expected %d or %d bytes, got %d", errSigningKeyInvalid, ed25519.SeedSize, ed25519.PrivateKeySize, len(keyBytes))
	}
}

func decodeReleaseSigningValue(value string) ([]byte, error) {
	clean := strings.TrimSpace(value)
	if clean == "" {
		return nil, errSigningKeyMissing
	}

	if decoded, err := hex.DecodeString(clean); err == nil {
		return decoded, nil
	}

	base64Variants := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, enc := range base64Variants {
		if decoded, err := enc.DecodeString(clean); err == nil {
			return decoded, nil
		}
	}

	return nil, errSigningKeyInvalid
}
