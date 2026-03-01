//go:build integration
// +build integration

package mtr

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTracer_LoopbackTrace(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()

	opts := DefaultOptions()
	opts.Target = "127.0.0.1"
	opts.MaxHops = 5
	opts.ProbesPerHop = 3
	opts.DNSResolve = false

	tracer, err := NewTracer(ctx, opts, log)
	if err != nil {
		t.Skipf("Cannot create tracer (may need root/cap_net_raw): %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	result, err := tracer.Run(ctx)
	if err != nil {
		t.Skipf("Trace failed (may need elevated privileges): %v", err)
	}

	require.NotNil(t, result)
	assert.Equal(t, "127.0.0.1", result.TargetIP)
	assert.True(t, result.TargetReached, "loopback target should be reached")
	assert.Equal(t, 4, result.IPVersion)
	assert.Equal(t, "icmp", result.Protocol)
	assert.GreaterOrEqual(t, result.TotalHops, 1, "should have at least 1 hop")
	assert.NotEmpty(t, result.Hops, "should have hop results")

	// First responding hop should be 127.0.0.1.
	for _, hop := range result.Hops {
		if hop.Addr != "" {
			assert.Equal(t, "127.0.0.1", hop.Addr, "loopback hop should be 127.0.0.1")
			assert.Greater(t, hop.Received, 0, "should have received replies")
			assert.Equal(t, float64(0), hop.LossPct, "loopback should have 0%% loss")
			break
		}
	}
}

func TestTracer_LoopbackIPv6(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()

	opts := DefaultOptions()
	opts.Target = "::1"
	opts.MaxHops = 5
	opts.ProbesPerHop = 3
	opts.DNSResolve = false

	tracer, err := NewTracer(ctx, opts, log)
	if err != nil {
		t.Skipf("Cannot create IPv6 tracer (may not be supported): %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	result, err := tracer.Run(ctx)
	if err != nil {
		t.Skipf("IPv6 trace failed: %v", err)
	}

	require.NotNil(t, result)
	assert.True(t, result.TargetReached, "IPv6 loopback should be reached")
	assert.Equal(t, 6, result.IPVersion)
}
