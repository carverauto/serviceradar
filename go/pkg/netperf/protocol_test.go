/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package netperf

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"math/big"
	"net/url"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

func TestClampRequestParamsAndValidateBounds(t *testing.T) {
	t.Parallel()

	bw, dur, omit, par, pkt := ClampRequestParams(0, 0, 10, 0, 0)
	require.Equal(t, DefaultBandwidthBps, bw)
	require.Equal(t, DefaultDurationSec, dur)
	require.Equal(t, DefaultDurationSec-1, omit)
	require.Equal(t, DefaultParallel, par)
	require.Equal(t, DefaultPacketLength, pkt)

	bw, dur, omit, par, pkt = ClampRequestParams(1, 999, 99, 99, 10)
	require.Equal(t, MinBandwidthBps, bw)
	require.Equal(t, MaxDurationSec, dur)
	require.Equal(t, MaxOmitSec, omit)
	require.Equal(t, MaxParallel, par)
	require.Equal(t, MinPacketLength, pkt)

	bw, dur, omit, par, pkt = ClampRequestParams(MaxBandwidthBps*10, 1, 1, 1, MaxPacketLength+100)
	require.Equal(t, MaxBandwidthBps, bw)
	require.Equal(t, uint32(1), dur)
	require.Equal(t, uint32(0), omit)
	require.Equal(t, uint32(1), par)
	require.Equal(t, MaxPacketLength, pkt)

	_, err := ValidateRequestBounds(&netperfpb.OpenSessionRequest{
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps: MinBandwidthBps,
		DurationSec:  5,
		OmitSec:      5, // must be strictly < duration_sec
		Parallel:     1,
	})
	require.ErrorIs(t, err, ErrInvalidRequest)
}

func TestUDP54ByteHeaderAndHMAC(t *testing.T) {
	t.Parallel()

	key := []byte("0123456789abcdef0123456789abcdef")
	var sid [UDPSessionSize]byte
	for i := range sid {
		sid[i] = byte(i + 1)
	}

	pkt := make([]byte, DefaultPacketLength)
	const seq = uint64(42)
	const sentNs = uint64(1795046400_123456789)
	require.NoError(t, EncodeUDPDatagram(pkt, key, UDPFlagData|UDPFlagOmit, sid, seq, sentNs))

	require.Equal(t, []byte("SRNP"), pkt[0:4])
	require.Equal(t, uint8(1), pkt[4])
	require.Equal(t, UDPFlagData|UDPFlagOmit, pkt[5])
	require.Equal(t, sid[:], pkt[6:22])
	require.Equal(t, seq, binary.BigEndian.Uint64(pkt[22:30]))
	require.Equal(t, sentNs, binary.BigEndian.Uint64(pkt[30:38]))

	flags, parsedSID, parsedSeq, parsedSent, ok := ParseUDPHeader(pkt)
	require.True(t, ok)
	require.Equal(t, UDPFlagData|UDPFlagOmit, flags)
	require.Equal(t, sid, parsedSID)
	require.Equal(t, seq, parsedSeq)
	require.Equal(t, sentNs, parsedSent)
	require.True(t, VerifyUDPMAC(pkt, key))

	// Tamper payload -> MAC fails
	tamperedPayload := append([]byte(nil), pkt...)
	tamperedPayload[UDPHeaderSize+10] ^= 0xff
	require.False(t, VerifyUDPMAC(tamperedPayload, key))

	// Tamper header -> MAC fails
	tamperedHeader := append([]byte(nil), pkt...)
	tamperedHeader[29] ^= 0x01
	require.False(t, VerifyUDPMAC(tamperedHeader, key))

	// Wrong key -> MAC fails
	wrongKey := append([]byte(nil), key...)
	wrongKey[0] ^= 0xff
	require.False(t, VerifyUDPMAC(pkt, wrongKey))

	// Short packet -> rejected
	_, _, _, _, ok = ParseUDPHeader(pkt[:UDPHeaderSize-1])
	require.False(t, ok)
	require.False(t, VerifyUDPMAC(pkt[:UDPHeaderSize-1], key))

	// Exact 54-byte HELLO packet succeeds
	hello := make([]byte, UDPHeaderSize)
	require.NoError(t, EncodeUDPDatagram(hello, key, UDPFlagHello, sid, 0, sentNs))
	require.True(t, VerifyUDPMAC(hello, key))
}

func TestRFC3550TrackerJitterLossAndSlidingWindow(t *testing.T) {
	t.Parallel()

	var tracker RFC3550Tracker
	// Packets 1, 2, 4, 3 (out of order), 4 (duplicate), 5 (loss of nothing)
	// Base offset: sent=1_000_000_000, arrival=0 -> transit0 = -1_000_000_000
	// Packet 1: arrival=0, sent=1_000_000_000
	// Packet 2: arrival=10_000_000, sent=1_010_000_000 (d=0 -> jitter=0)
	// Packet 4: arrival=24_000_000, sent=1_020_000_000 (d=4ms -> jitter = 4/16 = 0.25ms)
	// Packet 3: arrival=34_000_000, sent=1_030_000_000 (d=0 -> jitter = 0.25 - 0.25/16 = 0.234375ms)
	tracker.Record(1, 1_000_000_000, 0, 1200)
	tracker.Record(2, 1_010_000_000, 10_000_000, 1200)
	tracker.Record(4, 1_020_000_000, 24_000_000, 1200)
	tracker.Record(3, 1_030_000_000, 34_000_000, 1200)
	tracker.Record(4, 1_020_000_000, 35_000_000, 1200) // duplicate ignored

	// Tail loss: sender sent 6 packets (5 and 6 lost)
	stats := tracker.Snapshot(6)
	require.Equal(t, uint64(4), stats.PacketsReceived)
	require.Equal(t, uint64(2), stats.PacketsLost)
	require.Equal(t, uint64(1), stats.OutOfOrderPackets)
	require.Equal(t, uint64(4800), stats.BytesReceived)
	require.InDelta(t, 33.3333, stats.LossPercent, 0.01)
	require.InDelta(t, 0.234375, stats.JitterMs, 1e-6)

	// Jump sequence forward by 1500 (> 1024 window) and verify old seq is ignored cleanly
	tracker.Record(1505, 2_000_000_000, 1_000_000_000, 1200)
	tracker.Record(10, 1_050_000_000, 1_000_000_000, 1200)
	statsAfter := tracker.Snapshot(1505)
	require.Equal(t, uint64(5), statsAfter.PacketsReceived)
	require.Equal(t, uint64(1500), statsAfter.PacketsLost)
}

func TestExtractPeerIdentityFromCert(t *testing.T) {
	t.Parallel()

	mkCert := func(cn string, dns []string, uris []string) *x509.Certificate {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		require.NoError(t, err)
		parsedURIs := make([]*url.URL, 0, len(uris))
		for _, raw := range uris {
			u, uErr := url.Parse(raw)
			require.NoError(t, uErr)
			parsedURIs = append(parsedURIs, u)
		}
		tpl := &x509.Certificate{
			SerialNumber: big.NewInt(1),
			Subject:      pkix.Name{CommonName: cn},
			NotBefore:    time.Now().Add(-time.Hour),
			NotAfter:     time.Now().Add(time.Hour),
			DNSNames:     dns,
			URIs:         parsedURIs,
		}
		der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
		require.NoError(t, err)
		cert, err := x509.ParseCertificate(der)
		require.NoError(t, err)
		return cert
	}

	// Short CN + matching DNS + matching SPIFFE
	id, err := ExtractPeerIdentityFromCert(mkCert(
		"agent-spoke-01.default.serviceradar",
		[]string{"agent-spoke-01.default.serviceradar"},
		[]string{"spiffe://serviceradar.local/agent/default/agent-spoke-01"},
	))
	require.NoError(t, err)
	require.Equal(t, PeerIdentity{
		AgentID:     "agent-spoke-01",
		PartitionID: "default",
		TrustDomain: "serviceradar.local",
	}, id)

	// Long CN (SHA-256 hex) + DNS SAN retained
	id, err = ExtractPeerIdentityFromCert(mkCert(
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		[]string{"agent-very-long-id.prod-1.serviceradar"},
		nil,
	))
	require.NoError(t, err)
	require.Equal(t, "agent-very-long-id", id.AgentID)
	require.Equal(t, "prod-1", id.PartitionID)

	// Conflicting DNS vs SPIFFE URI rejected
	_, err = ExtractPeerIdentityFromCert(mkCert(
		"agent-a.default.serviceradar",
		[]string{"agent-a.default.serviceradar"},
		[]string{"spiffe://serviceradar.local/agent/default/agent-b"},
	))
	require.ErrorIs(t, err, ErrPeerIdentityConflict)

	// Multiple SPIFFE URIs rejected
	_, err = ExtractPeerIdentityFromCert(mkCert(
		"",
		nil,
		[]string{
			"spiffe://serviceradar.local/agent/default/agent-a",
			"spiffe://serviceradar.local/agent/default/agent-b",
		},
	))
	require.ErrorIs(t, err, ErrPeerIdentityConflict)

	// Missing identity rejected
	_, err = ExtractPeerIdentityFromCert(mkCert("unrelated.example.com", nil, nil))
	require.ErrorIs(t, err, ErrPeerIdentityInvalid)
}
