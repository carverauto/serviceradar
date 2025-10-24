package hashutil

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
)

// DecodeSHA256String attempts to decode the provided checksum string which may be
// hex-encoded or base64/base64url-encoded. It returns the raw 32-byte digest.
func DecodeSHA256String(s string) ([]byte, error) {
	clean := strings.TrimSpace(s)
	if clean == "" {
		return nil, fmt.Errorf("empty checksum string")
	}

	if decoded, err := hex.DecodeString(clean); err == nil {
		return decoded, nil
	}

	// Try several base64 alphabets to accommodate metadata encodings.
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

	return nil, fmt.Errorf("unsupported checksum encoding")
}

// CanonicalHexSHA256 decodes the input checksum and re-encodes it as a
// lowercase hexadecimal string.
func CanonicalHexSHA256(s string) (string, error) {
	decoded, err := DecodeSHA256String(s)
	if err != nil {
		return "", err
	}

	return hex.EncodeToString(decoded), nil
}

// EqualSHA256 reports whether the provided checksum string (hex or base64) matches
// the supplied SHA256 digest.
func EqualSHA256(expected string, actual [32]byte) bool {
	decoded, err := DecodeSHA256String(expected)
	if err != nil {
		return false
	}

	return subtle.ConstantTimeCompare(decoded, actual[:]) == 1
}
