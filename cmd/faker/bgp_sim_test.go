package main

import (
	"math/rand"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestDefaultBGPPeersIncludesIPv4AndIPv6AndISP(t *testing.T) {
	peers := defaultBGPPeers()
	require.NotEmpty(t, peers)

	var hasIPv4, hasIPv6, hasISP bool
	for _, p := range peers {
		if p.PeerASN == 10242 {
			hasISP = true
		}
		if p.IP == "204.209.51.58" {
			hasIPv4 = true
		}
		if p.IP == "2605:8400:ff:142::" {
			hasIPv6 = true
		}
	}

	require.True(t, hasIPv4)
	require.True(t, hasIPv6)
	require.True(t, hasISP)
}

func TestSplitHostPort(t *testing.T) {
	host, port, err := splitHostPort("127.0.0.1:11019")
	require.NoError(t, err)
	require.Equal(t, "127.0.0.1", host)
	require.Equal(t, 11019, port)

	_, _, err = splitHostPort("not-a-hostport")
	require.Error(t, err)
}

func TestRandomDurationBounds(t *testing.T) {
	rng := rand.New(rand.NewSource(42)) //nolint:gosec // deterministic test seed
	minD := 2 * time.Second
	maxD := 5 * time.Second

	for i := 0; i < 100; i++ {
		d := randomDuration(rng, minD, maxD)
		require.GreaterOrEqual(t, d, minD)
		require.LessOrEqual(t, d, maxD)
	}
}

func TestConfigValidateRequiresBMPWhenBGPEnabled(t *testing.T) {
	cfg := &Config{}
	cfg.applyDefaults()
	cfg.Simulation.BGP.Enabled = true
	cfg.Simulation.BGP.BMPCollectorAddress = ""

	err := cfg.Validate()
	require.ErrorIs(t, err, errBGPBMPCollectorRequired)
}

func TestConfigValidateRequiresMaxPrefixesWhenBGPEnabled(t *testing.T) {
	cfg := &Config{}
	cfg.applyDefaults()
	cfg.Simulation.BGP.Enabled = true
	cfg.Simulation.BGP.MaxPrefixesPerTick = 0

	err := cfg.Validate()
	require.ErrorIs(t, err, errBGPMaxPrefixesRequired)
}
