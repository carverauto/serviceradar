package agent

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
)

func TestCommandTimeoutCap_NoCommandTTLUsesCap(t *testing.T) {
	t.Parallel()

	got := commandTimeoutCap(nil)
	if got != defaultOnDemandMtrDeadline {
		t.Fatalf("expected %v, got %v", defaultOnDemandMtrDeadline, got)
	}
}

func TestCommandTimeoutCap_ExpiredReturnsZero(t *testing.T) {
	t.Parallel()

	cmd := &proto.CommandRequest{
		CreatedAt:  time.Now().Add(-2 * time.Minute).Unix(),
		TtlSeconds: 60,
	}

	got := commandTimeoutCap(cmd)
	if got != 0 {
		t.Fatalf("expected 0, got %v", got)
	}
}

func TestCommandTimeoutCap_CapsToRemainingTTL(t *testing.T) {
	t.Parallel()

	cmd := &proto.CommandRequest{
		CreatedAt:  time.Now().Add(-10 * time.Second).Unix(),
		TtlSeconds: 20,
	}

	got := commandTimeoutCap(cmd)
	if got <= 0 || got > 12*time.Second {
		t.Fatalf("expected timeout close to 10s remaining, got %v", got)
	}
}

func TestCommandTimeoutCap_UsesCapWhenTTLIsLonger(t *testing.T) {
	t.Parallel()

	cmd := &proto.CommandRequest{
		CreatedAt:  time.Now().Unix(),
		TtlSeconds: 120,
	}

	got := commandTimeoutCap(cmd)
	if got != defaultOnDemandMtrDeadline {
		t.Fatalf("expected %v, got %v", defaultOnDemandMtrDeadline, got)
	}
}

func TestOnDemandMtrOptions_UsesPayloadProtocolAndMaxHops(t *testing.T) {
	t.Parallel()

	opts := onDemandMtrOptions(mtrRunPayload{
		Target:   "8.8.8.8",
		Protocol: "udp",
		MaxHops:  12,
	})

	if opts.Target != "8.8.8.8" {
		t.Fatalf("expected target 8.8.8.8, got %q", opts.Target)
	}
	if opts.Protocol != mtr.ProtocolUDP {
		t.Fatalf("expected protocol udp, got %v", opts.Protocol)
	}
	if opts.MaxHops != 12 {
		t.Fatalf("expected max_hops 12, got %d", opts.MaxHops)
	}
}

func TestOnDemandMtrOptions_ClampsMaxHops(t *testing.T) {
	t.Parallel()

	opts := onDemandMtrOptions(mtrRunPayload{
		Target:  "1.1.1.1",
		MaxHops: 9999,
	})

	if opts.MaxHops != mtrMaxHopsUpperBound {
		t.Fatalf("expected clamped max_hops %d, got %d", mtrMaxHopsUpperBound, opts.MaxHops)
	}
}
