package agent

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseMtrCheckConfig_ValidConfig(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:     "mtr-check-1",
		CheckType:   "mtr",
		Name:        "Trace to 8.8.8.8",
		Enabled:     true,
		IntervalSec: 300,
		TimeoutSec:  30,
		Target:      "8.8.8.8",
		Settings: map[string]string{
			"device_uid":        "dev-123",
			"max_hops":          "20",
			"probes_per_hop":    "5",
			"protocol":          "udp",
			"probe_interval_ms": "100",
			"packet_size":       "64",
			"dns_resolve":       "true",
		},
	}

	cfg := parseMtrCheckConfig(check)
	require.NotNil(t, cfg)

	assert.Equal(t, "mtr-check-1", cfg.ID)
	assert.Equal(t, "Trace to 8.8.8.8", cfg.Name)
	assert.Equal(t, "8.8.8.8", cfg.Target)
	assert.Equal(t, "dev-123", cfg.DeviceID)
	assert.Equal(t, 300*time.Second, cfg.Interval)
	assert.Equal(t, 30*time.Second, cfg.Timeout)
	assert.True(t, cfg.Enabled)
	assert.Equal(t, 20, cfg.MaxHops)
	assert.Equal(t, 5, cfg.ProbesPerHop)
	assert.Equal(t, mtr.ProtocolUDP, cfg.Protocol)
	assert.Equal(t, 100, cfg.ProbeIntervalMs)
	assert.Equal(t, 64, cfg.PacketSize)
	assert.True(t, cfg.DNSResolve)
}

func TestParseMtrCheckConfig_Defaults(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:     "mtr-defaults",
		CheckType:   "mtr",
		Name:        "Default MTR",
		Enabled:     true,
		IntervalSec: 60,
		TimeoutSec:  10,
		Target:      "example.com",
	}

	cfg := parseMtrCheckConfig(check)
	require.NotNil(t, cfg)

	assert.Equal(t, mtr.DefaultMaxHops, cfg.MaxHops)
	assert.Equal(t, mtr.DefaultProbesPerHop, cfg.ProbesPerHop)
	assert.Equal(t, mtr.ProtocolICMP, cfg.Protocol)
	assert.Equal(t, mtr.DefaultProbeIntervalMs, cfg.ProbeIntervalMs)
	assert.Equal(t, mtr.DefaultPacketSize, cfg.PacketSize)
	assert.True(t, cfg.DNSResolve)
}

func TestParseMtrCheckConfig_NilCheck(t *testing.T) {
	t.Parallel()

	cfg := parseMtrCheckConfig(nil)
	assert.Nil(t, cfg)
}

func TestParseMtrCheckConfig_WrongType(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "icmp-1",
		CheckType: "icmp",
		Enabled:   true,
		Target:    "8.8.8.8",
	}

	cfg := parseMtrCheckConfig(check)
	assert.Nil(t, cfg, "non-mtr check type should return nil")
}

func TestParseMtrCheckConfig_Disabled(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "mtr-disabled",
		CheckType: "mtr",
		Enabled:   false,
		Target:    "8.8.8.8",
	}

	cfg := parseMtrCheckConfig(check)
	assert.Nil(t, cfg, "disabled check should return nil")
}

func TestParseMtrCheckConfig_EmptyTarget(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "mtr-no-target",
		CheckType: "mtr",
		Enabled:   true,
		Target:    "",
	}

	cfg := parseMtrCheckConfig(check)
	assert.Nil(t, cfg, "empty target should return nil")
}

func TestParseMtrCheckConfig_EmptyCheckID(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "",
		CheckType: "mtr",
		Enabled:   true,
		Target:    "8.8.8.8",
	}

	cfg := parseMtrCheckConfig(check)
	assert.Nil(t, cfg, "empty check ID should return nil")
}

func TestParseMtrCheckConfig_ProtocolTCP(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "mtr-tcp",
		CheckType: "mtr",
		Enabled:   true,
		Target:    "example.com",
		Settings:  map[string]string{"protocol": "tcp"},
	}

	cfg := parseMtrCheckConfig(check)
	require.NotNil(t, cfg)
	assert.Equal(t, mtr.ProtocolTCP, cfg.Protocol)
}

func TestParseMtrCheckConfig_TCPPort(t *testing.T) {
	t.Parallel()

	cases := []struct {
		setting string
		want    int
	}{
		{setting: "8443", want: 8443},
		{setting: "80\n", want: 80},
		{setting: "0", want: mtr.DefaultTCPPort},
		{setting: "70000", want: mtr.DefaultTCPPort},
		{setting: "https", want: mtr.DefaultTCPPort},
	}

	for _, tc := range cases {
		setting, want := tc.setting, tc.want
		check := &proto.AgentCheckConfig{
			CheckId:   "mtr-tcp-port",
			CheckType: "mtr",
			Enabled:   true,
			Target:    "host01.example.com",
			Settings:  map[string]string{"protocol": "tcp", "tcp_port": setting},
		}

		cfg := parseMtrCheckConfig(check)
		require.NotNil(t, cfg)
		assert.Equal(t, want, cfg.TCPPort, "tcp_port=%q", setting)
	}
}

func TestParseMtrCheckConfig_DNSResolveFalse(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "mtr-no-dns",
		CheckType: "mtr",
		Enabled:   true,
		Target:    "8.8.8.8",
		Settings:  map[string]string{"dns_resolve": "false"},
	}

	cfg := parseMtrCheckConfig(check)
	require.NotNil(t, cfg)
	assert.False(t, cfg.DNSResolve)
}

func TestParseMtrCheckConfig_DeviceIDFallback(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "mtr-dev-fallback",
		CheckType: "mtr",
		Enabled:   true,
		Target:    "10.0.0.1",
		Settings:  map[string]string{"device_id": "dev-456"},
	}

	cfg := parseMtrCheckConfig(check)
	require.NotNil(t, cfg)
	assert.Equal(t, "dev-456", cfg.DeviceID)
}

func TestParseMtrCheckConfig_ClampsResourceIntensiveSettings(t *testing.T) {
	t.Parallel()

	check := &proto.AgentCheckConfig{
		CheckId:   "mtr-clamped",
		CheckType: "mtr",
		Enabled:   true,
		Target:    "8.8.8.8",
		Settings: map[string]string{
			"max_hops":          "9999",
			"probes_per_hop":    "9999",
			"probe_interval_ms": "999999",
			"packet_size":       "65535",
		},
	}

	cfg := parseMtrCheckConfig(check)
	require.NotNil(t, cfg)
	assert.Equal(t, mtrMaxHopsUpperBound, cfg.MaxHops)
	assert.Equal(t, mtrProbesPerHopUpperBound, cfg.ProbesPerHop)
	assert.Equal(t, mtrProbeIntervalMsUpperBound, cfg.ProbeIntervalMs)
	assert.Equal(t, mtrPacketSizeUpperBound, cfg.PacketSize)
}

func TestMtrCheckerState_NewState(t *testing.T) {
	t.Parallel()

	state := newMtrCheckerState()
	require.NotNil(t, state)
	assert.NotNil(t, state.checks)
	assert.NotNil(t, state.lastRun)
	assert.Empty(t, state.checks)
	assert.Empty(t, state.lastRun)
}

func TestParseMtrCheckConfig_TCPSynRetries(t *testing.T) {
	t.Parallel()

	cases := []struct {
		setting string
		want    int
	}{
		{setting: "0", want: 0},
		{setting: "3", want: 3},
		{setting: "4", want: mtr.DefaultTCPSynRetries},
		{setting: "-1", want: mtr.DefaultTCPSynRetries},
	}

	for _, tc := range cases {
		check := &proto.AgentCheckConfig{
			CheckId:   "mtr-tcp-retries",
			CheckType: "mtr",
			Enabled:   true,
			Target:    "host01.example.com",
			Settings:  map[string]string{"protocol": "tcp", "tcp_syn_retries": tc.setting},
		}

		cfg := parseMtrCheckConfig(check)
		require.NotNil(t, cfg)
		assert.Equal(t, tc.want, cfg.TCPSynRetries, "tcp_syn_retries=%q", tc.setting)
	}
}
