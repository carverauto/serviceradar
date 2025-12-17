package mapper

import (
	"net"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
)

func TestCollectIPsFromRange_LargeRangeCappedUnique(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	ip, ipNet, err := net.ParseCIDR("192.168.0.0/16")
	if err != nil {
		t.Fatalf("parse CIDR: %v", err)
	}

	ones, bits := ipNet.Mask.Size()
	hostBits := bits - ones

	targets := engine.collectIPsFromRange(ip, ipNet, hostBits, make(map[string]bool))
	if got, want := len(targets), defaultMaxIPRange; got != want {
		t.Fatalf("unexpected target count: got %d want %d", got, want)
	}

	if targets[0] != "192.168.0.0" {
		t.Fatalf("unexpected first target: got %q want %q", targets[0], "192.168.0.0")
	}

	if targets[len(targets)-1] != "192.168.0.255" {
		t.Fatalf("unexpected last target: got %q want %q", targets[len(targets)-1], "192.168.0.255")
	}

	unique := make(map[string]struct{}, len(targets))
	for _, target := range targets {
		if _, ok := unique[target]; ok {
			t.Fatalf("duplicate target: %q", target)
		}
		unique[target] = struct{}{}

		if parsed := net.ParseIP(target); parsed == nil || !ipNet.Contains(parsed) {
			t.Fatalf("target not in cidr: %q", target)
		}
	}

	if len(unique) <= 1 {
		t.Fatalf("expected more than one unique target, got %d", len(unique))
	}
}

func TestExpandCIDR_SmallRangeReturnsUsableHosts(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	targets := engine.expandCIDR("192.168.0.0/30", make(map[string]bool))
	if got, want := len(targets), 2; got != want {
		t.Fatalf("unexpected target count: got %d want %d", got, want)
	}

	if targets[0] != "192.168.0.1" || targets[1] != "192.168.0.2" {
		t.Fatalf("unexpected targets: %v", targets)
	}
}
