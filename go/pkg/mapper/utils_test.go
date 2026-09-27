package mapper

import (
	"errors"
	"testing"

	"github.com/gosnmp/gosnmp"
)

func TestCreateSNMPClientUsesTargetSpecificCredentials(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}

	base := &SNMPCredentials{
		Version:   SNMPVersion2c,
		Community: "example-fallback",
		TargetSpecific: map[string]*SNMPCredentials{
			"198.51.100.10": {
				Version:   SNMPVersion2c,
				Community: "example-scoped",
			},
		},
	}

	client, err := engine.createSNMPClient("198.51.100.10", base)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if client.Community != "example-scoped" {
		t.Fatalf("expected target-specific community, got %q", client.Community)
	}

	fallbackClient, err := engine.createSNMPClient("198.51.100.20", base)
	if err != nil {
		t.Fatalf("unexpected error for non-scoped target: %v", err)
	}

	if fallbackClient.Community != "example-fallback" {
		t.Fatalf("expected base community for unscoped target, got %q", fallbackClient.Community)
	}
}

// An explicit empty credential object in target_specific must suppress SNMP
// for that address rather than silently reusing the collector's fallback
// credential.
func TestCreateSNMPClientRejectsEmptyTargetSpecificCredentials(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}

	base := &SNMPCredentials{
		Version:   SNMPVersion2c,
		Community: "example-fallback",
		TargetSpecific: map[string]*SNMPCredentials{
			"198.51.100.10": {},
		},
	}

	client, err := engine.createSNMPClient("198.51.100.10", base)
	if err == nil {
		t.Fatalf("expected error for suppressed target, got client with version %q", client.Version)
	}

	if !errors.Is(err, ErrUnsupportedSNMPVersion) {
		t.Fatalf("expected ErrUnsupportedSNMPVersion, got %v", err)
	}

	if client != nil {
		t.Fatalf("expected nil client on suppressed target, got %+v", client)
	}

	fallbackClient, err := engine.createSNMPClient("198.51.100.20", base)
	if err != nil {
		t.Fatalf("unexpected error for non-suppressed target: %v", err)
	}

	if fallbackClient.Community != "example-fallback" {
		t.Fatalf("expected base community for unscoped target, got %q", fallbackClient.Community)
	}
}

func TestConfigureClientVersionRejectsUnknownVersion(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	client := &gosnmp.GoSNMP{}

	err := engine.configureClientVersion(client, &SNMPCredentials{})
	if !errors.Is(err, ErrUnsupportedSNMPVersion) {
		t.Fatalf("expected ErrUnsupportedSNMPVersion, got %v", err)
	}
}
