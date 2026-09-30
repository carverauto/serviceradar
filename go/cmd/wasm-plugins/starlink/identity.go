package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

const (
	sourceName = "starlink"

	terminalIDPrefix = "starlink:ut:"
	routerIDPrefix   = "starlink:router:"
)

// Identity rules. A Starlink device is identified only by its vendor device ID
// (and, for terminals, the kit serial). Addresses are never identity: public
// IPs are shared behind carrier-grade NAT, and the vendor-default LAN address
// of a terminal or router is the same at every site, so treating either as an
// identifier would merge unrelated devices.

// normalizeTerminalID returns the canonical vendor terminal ID. The Management
// API reports it bare; telemetry prefixes it with "ut". Both forms map to the
// same device.
func normalizeTerminalID(raw string) string {
	id := strings.ToLower(strings.TrimSpace(raw))
	id = strings.TrimPrefix(id, "ut")
	if isPlaceholderID(id) {
		return ""
	}
	return id
}

// normalizeRouterID returns the canonical vendor router ID ("Router-" plus hex).
func normalizeRouterID(raw string) string {
	id := strings.TrimSpace(raw)
	suffix, ok := cutPrefixFold(id, "router-")
	if !ok || isPlaceholderID(suffix) {
		return ""
	}
	return "Router-" + strings.ToLower(suffix)
}

func terminalDeviceID(rawTerminalID string) string {
	id := normalizeTerminalID(rawTerminalID)
	if id == "" {
		return ""
	}
	return terminalIDPrefix + id
}

func routerDeviceID(rawRouterID string) string {
	id := normalizeRouterID(rawRouterID)
	if id == "" {
		return ""
	}
	return routerIDPrefix + strings.TrimPrefix(id, "Router-")
}

// normalizeSerial drops blank and placeholder serials so they never become a
// strong identifier shared by unrelated devices.
func normalizeSerial(raw string) string {
	serial := strings.ToUpper(strings.TrimSpace(raw))
	if isPlaceholderID(serial) {
		return ""
	}
	return serial
}

// isPlaceholderID reports values that look like an identifier but identify
// nothing: empty, all zeros (with or without separators), or a literal
// unknown marker.
func isPlaceholderID(value string) bool {
	v := strings.ToLower(strings.TrimSpace(value))
	switch v {
	case "", "null", "none", "unknown", "n/a", "-":
		return true
	}
	for _, r := range v {
		if r != '0' && r != '-' && r != ':' {
			return false
		}
	}
	return true
}

// sourceInstance scopes snapshots to one Starlink account without publishing
// the account number itself in labels or snapshot keys.
func sourceInstance(accountNumber string) string {
	sum := sha256.Sum256([]byte(strings.ToUpper(strings.TrimSpace(accountNumber))))
	return "starlink-" + hex.EncodeToString(sum[:8])
}

func cutPrefixFold(value, prefix string) (string, bool) {
	if len(value) < len(prefix) || !strings.EqualFold(value[:len(prefix)], prefix) {
		return value, false
	}
	return value[len(prefix):], true
}
