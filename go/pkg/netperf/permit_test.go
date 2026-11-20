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
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

func signTestPermit(t *testing.T, priv ed25519.PrivateKey, p *netperfpb.NetperfPermitV1) *netperfpb.NetperfPermitV1 {
	t.Helper()
	p.Signature = ed25519.Sign(priv, CanonicalPermitPreimage(p))
	return p
}

func makeTestTrustSnapshot(t *testing.T, agentID string, issuerID, keyID []byte, pub ed25519.PublicKey, status string, purposes []string) *edgerecord.TrustSnapshot {
	t.Helper()
	doc := map[string]any{
		"clock_tolerance_nano": int64(300_000_000_000),
		"keys": []map[string]any{{
			"issuer_id":     issuerID,
			"issuer_key_id": keyID,
			"public_key":    pub,
			"purposes":      purposes,
			"status":        status,
		}},
		"fences":             []any{},
		"scopes":             []any{},
		"terminal_intervals": []any{},
	}
	raw, err := json.Marshal(doc)
	require.NoError(t, err)
	snap, err := edgerecord.ParseTrustDocument(raw, []byte(agentID), 1)
	require.NoError(t, err)
	return snap
}

func TestElixirGoldenPermitVectorParity(t *testing.T) {
	t.Parallel()

	// Generated directly by Elixir ServiceRadar.Edge.NetperfPermitSigning / IssuerKey.from_seed(<<1::256>>)
	pubBytes, err := hex.DecodeString("4cb5abf6ad79fbf5abbccafcc269d85cd2651ed4b885b5869f241aedf0a5ba29")
	require.NoError(t, err)
	keyIDBytes, err := hex.DecodeString("7ce781dcaab75533f19da346bca67455")
	require.NoError(t, err)
	wantPreimageHash, err := hex.DecodeString("011a9e64759f70bc17d5eb2488a8c019610dda0de44c9dd9339379943ec64fd5")
	require.NoError(t, err)
	sigBytes, err := hex.DecodeString("43c869c28cdc8bcee2cf0705dec2c47ecf6ea4802ae286bc2dbd689c0bcd594e90b25873255bc2eaf9448490a9ddcd91b77d5fa78dc4351f897805e1b8b34607")
	require.NoError(t, err)

	const dayBucket = int64(1795046400) // 2026-11-18T00:00:00Z
	permit := &netperfpb.NetperfPermitV1{
		PermitVersion:    1,
		PermitId:         "268af2fe-7ebf-6d0c-b687-836bd4048820",
		PartitionId:      "default",
		SenderAgentId:    "agent-spoke-01",
		ResponderAgentId: "agent-hub-01",
		PolicyId:         "11111111-1111-1111-1111-111111111111",
		MaxBandwidthBps:  100_000_000,
		MaxDurationSec:   10,
		MaxParallel:      2,
		// Deliberately out of order to verify canonical sorting parity with Elixir.
		AllowedProtocols: []netperfpb.NetperfProtocol{
			netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
			netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		},
		AllowedDirections: []netperfpb.NetperfDirection{
			netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
		},
		IssuedAtUnix:   dayBucket - 300,
		ExpiresAtUnix:  dayBucket + 8*86_400,
		AuthorityEpoch: 5,
		IssuerId:       "serviceradar-core",
		IssuerKeyId:    keyIDBytes,
		Algorithm:      "ed25519",
		Signature:      sigBytes,
	}

	gotPreimage := CanonicalPermitPreimage(permit)
	gotHash := sha256.Sum256(gotPreimage)
	require.Equal(t, wantPreimageHash, gotHash[:])

	snap := makeTestTrustSnapshot(t, "agent-hub-01", []byte("serviceradar-core"), keyIDBytes, pubBytes, "valid", []string{"production", "source", "delivery"})
	resolver := TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return snap }}

	req := &netperfpb.OpenSessionRequest{
		Permit:       permit,
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
		BandwidthBps: 50_000_000,
		DurationSec:  5,
		OmitSec:      1,
		Parallel:     2,
	}
	err = VerifyPermit(
		permit, req,
		PeerIdentity{AgentID: "agent-spoke-01", PartitionID: "default"},
		"agent-hub-01", "default", 5,
		time.Unix(dayBucket+3600, 0).UTC(),
		resolver,
	)
	require.NoError(t, err)
}

func TestVerifyPermitEnforcement(t *testing.T) {
	t.Parallel()

	seed := bytes.Repeat([]byte{0x2a}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	keyID := []byte("0123456789abcdef")
	now := time.Unix(1_795_000_000, 0).UTC()

	basePermit := func() *netperfpb.NetperfPermitV1 {
		return signTestPermit(t, priv, &netperfpb.NetperfPermitV1{
			PermitVersion:    1,
			PermitId:         "permit-1",
			PartitionId:      "default",
			SenderAgentId:    "agent-spoke-01",
			ResponderAgentId: "agent-hub-01",
			PolicyId:         "policy-1",
			MaxBandwidthBps:  100_000_000,
			MaxDurationSec:   10,
			MaxParallel:      4,
			AllowedProtocols: []netperfpb.NetperfProtocol{netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP},
			AllowedDirections: []netperfpb.NetperfDirection{
				netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			},
			IssuedAtUnix:   now.Unix() - 60,
			ExpiresAtUnix:  now.Unix() + 300,
			AuthorityEpoch: 3,
			IssuerId:       "serviceradar-core",
			IssuerKeyId:    keyID,
			Algorithm:      "ed25519",
		})
	}

	baseReq := func(p *netperfpb.NetperfPermitV1) *netperfpb.OpenSessionRequest {
		return &netperfpb.OpenSessionRequest{
			Permit:       p,
			Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
			Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			BandwidthBps: 50_000_000,
			DurationSec:  5,
			OmitSec:      1,
			Parallel:     2,
		}
	}

	validSnap := makeTestTrustSnapshot(t, "agent-hub-01", []byte("serviceradar-core"), keyID, pub, "valid", []string{"production"})
	validResolver := TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return validSnap }}
	peer := PeerIdentity{AgentID: "agent-spoke-01", PartitionID: "default"}

	// Valid baseline
	p := basePermit()
	require.NoError(t, VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 3, now, validResolver))

	// Epoch fenced
	err := VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 4, now, validResolver)
	require.ErrorIs(t, err, ErrPermitEpochFenced)

	// Historically revoked key rejected for live permits
	revSnap := makeTestTrustSnapshot(t, "agent-hub-01", []byte("serviceradar-core"), keyID, pub, "historically_revoked", []string{"production"})
	revResolver := TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return revSnap }}
	err = VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 3, now, revResolver)
	require.ErrorIs(t, err, ErrPermitKeyRevoked)

	// Wrong purpose (no production) rejected
	delSnap := makeTestTrustSnapshot(t, "agent-hub-01", []byte("serviceradar-core"), keyID, pub, "valid", []string{"delivery"})
	delResolver := TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return delSnap }}
	err = VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 3, now, delResolver)
	require.ErrorIs(t, err, ErrPermitKeyInvalid)

	// Expired permit rejected
	err = VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 3, time.Unix(p.ExpiresAtUnix, 0), validResolver)
	require.ErrorIs(t, err, ErrPermitExpired)

	// Within clock skew tolerance of IssuedAtUnix passes; outside skew fails
	skewPassNow := time.Unix(p.IssuedAtUnix-100, 0)
	require.NoError(t, VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 3, skewPassNow, validResolver))
	skewFailNow := time.Unix(p.IssuedAtUnix-301, 0)
	require.ErrorIs(t, VerifyPermit(p, baseReq(p), peer, "agent-hub-01", "default", 3, skewFailNow, validResolver), ErrPermitExpired)

	// Peer identity mismatch rejected
	err = VerifyPermit(p, baseReq(p), PeerIdentity{AgentID: "other-spoke", PartitionID: "default"}, "agent-hub-01", "default", 3, now, validResolver)
	require.ErrorIs(t, err, ErrPermitScopeMismatch)

	// Request ceiling exceeded rejected
	overReq := baseReq(p)
	overReq.BandwidthBps = 200_000_000
	require.ErrorIs(t, VerifyPermit(p, overReq, peer, "agent-hub-01", "default", 3, now, validResolver), ErrPermitCeilingExceeded)

	overProto := baseReq(p)
	overProto.Protocol = netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP
	require.ErrorIs(t, VerifyPermit(p, overProto, peer, "agent-hub-01", "default", 3, now, validResolver), ErrPermitCeilingExceeded)

	// Tampered signature rejected
	tampered := basePermit()
	tampered.Signature[0] ^= 0xff
	require.ErrorIs(t, VerifyPermit(tampered, baseReq(tampered), peer, "agent-hub-01", "default", 3, now, validResolver), ErrPermitSignatureInvalid)
}
