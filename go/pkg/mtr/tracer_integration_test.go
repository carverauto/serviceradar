//go:build integration
// +build integration

package mtr

import (
	"context"
	"net"
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTracer_LoopbackTrace(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()

	opts := DefaultOptions("127.0.0.1")
	opts.MaxHops = 5
	opts.ProbesPerHop = 3
	opts.DNSResolve = false

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tracer, err := NewTracer(ctx, opts, log)
	if err != nil {
		t.Skipf("Cannot create tracer (may need root/cap_net_raw): %v", err)
	}

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

	opts := DefaultOptions("::1")
	opts.MaxHops = 5
	opts.ProbesPerHop = 3
	opts.DNSResolve = false

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tracer, err := NewTracer(ctx, opts, log)
	if err != nil {
		t.Skipf("Cannot create IPv6 tracer (may not be supported): %v", err)
	}

	result, err := tracer.Run(ctx)
	if err != nil {
		t.Skipf("IPv6 trace failed: %v", err)
	}

	require.NotNil(t, result)
	assert.True(t, result.TargetReached, "IPv6 loopback should be reached")
	assert.Equal(t, 6, result.IPVersion)
}

// runLoopbackTCPTrace traces 127.0.0.1 over TCP to port. Crafting SYNs needs a
// raw socket, so these tests run only as root; anything that goes wrong after
// that is a failure, not a skip.
func runLoopbackTCPTrace(t *testing.T, port int) *TraceResult {
	t.Helper()

	if os.Geteuid() != 0 {
		t.Skip("TCP loopback trace needs root for raw sockets")
	}

	opts := DefaultOptions("127.0.0.1")
	opts.Protocol = ProtocolTCP
	opts.TCPPort = port
	opts.MaxHops = 3
	opts.ProbesPerHop = 2
	opts.Timeout = time.Second
	opts.DNSResolve = false

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tracer, err := NewTracer(ctx, opts, logger.NewTestLogger())
	require.NoError(t, err)

	result, err := tracer.Run(ctx)
	require.NoError(t, err)
	require.NotNil(t, result)

	return result
}

func TestTracer_TCPLoopbackListenerReachedBySynAck(t *testing.T) {
	t.Parallel()

	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp4", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { _ = ln.Close() })

	addr, ok := ln.Addr().(*net.TCPAddr)
	require.True(t, ok)

	result := runLoopbackTCPTrace(t, addr.Port)

	assert.True(t, result.TargetReached, "a listening port should answer with SYN-ACK")
	assert.Equal(t, 1, result.TotalHops, "loopback is one hop")
	assert.Equal(t, addr.Port, result.TCPPort)
	require.NotEmpty(t, result.Hops)
	assert.Equal(t, "127.0.0.1", result.Hops[0].Addr)
	assert.Positive(t, result.Hops[0].ReplySynack, "hop 1 should count the SYN-ACK")
}

func TestTracer_TCPClosedLoopbackPortReachedByRST(t *testing.T) {
	t.Parallel()

	// Take a free port, then close it so the kernel answers with RST.
	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp4", "127.0.0.1:0")
	require.NoError(t, err)

	addr, ok := ln.Addr().(*net.TCPAddr)
	require.True(t, ok)
	require.NoError(t, ln.Close())

	result := runLoopbackTCPTrace(t, addr.Port)

	assert.True(t, result.TargetReached, "a closed port should answer with RST")
	assert.Equal(t, 1, result.TotalHops, "loopback is one hop")
	require.NotEmpty(t, result.Hops)
	assert.Equal(t, "127.0.0.1", result.Hops[0].Addr)
	assert.Positive(t, result.Hops[0].ReplyRst, "hop 1 should count the RST")
	assert.Zero(t, result.Hops[0].ReplySynack, "a closed port never answers SYN-ACK")
}
