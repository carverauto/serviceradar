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
	"crypto/ed25519"
	"encoding/binary"
	"fmt"
	"slices"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

const (
	permitPreimageDomain = "serviceradar.netperf.permit.v1"
	permitVersionV1      = uint32(1)
	permitAlgorithmEd    = "ed25519"
)

// PermitKeyResolver resolves Ed25519 signing keys for NetperfPermitV1 verification.
type PermitKeyResolver interface {
	ResolvePermitKey(issuerID, issuerKeyID []byte) (ed25519.PublicKey, edgerecord.KeyStatus, int64, bool)
}

// TrustSnapshotKeyResolver adapts a dynamic *edgerecord.TrustSnapshot provider
// to PermitKeyResolver.
type TrustSnapshotKeyResolver struct {
	Snapshot func() *edgerecord.TrustSnapshot
}

// ResolvePermitKey delegates permit key lookup to the latest TrustSnapshot.
func (r TrustSnapshotKeyResolver) ResolvePermitKey(issuerID, issuerKeyID []byte) (ed25519.PublicKey, edgerecord.KeyStatus, int64, bool) {
	if r.Snapshot == nil {
		return nil, edgerecord.KeyUnavailable, 0, false
	}
	snap := r.Snapshot()
	if snap == nil {
		return nil, edgerecord.KeyUnavailable, 0, false
	}
	return snap.ResolvePermitKey(issuerID, issuerKeyID)
}

// CanonicalPermitPreimage encodes permit using the exact binary framing as
// Elixir's ServiceRadar.Edge.NetperfPermitSigning.preimage/1.
func CanonicalPermitPreimage(permit *netperfpb.NetperfPermitV1) []byte {
	if permit == nil {
		return nil
	}

	protocols := normalizePermitProtocols(permit.GetAllowedProtocols())
	directions := normalizePermitDirections(permit.GetAllowedDirections())

	buf := make([]byte, 0, 512)
	buf = appendLenBytes(buf, []byte(permitPreimageDomain))
	buf = appendUint64(buf, uint64(permit.GetPermitVersion()))
	buf = appendLenBytes(buf, []byte(permit.GetPermitId()))
	buf = appendLenBytes(buf, []byte(permit.GetIssuerId()))
	buf = appendLenBytes(buf, permit.GetIssuerKeyId())
	buf = appendLenBytes(buf, []byte(permit.GetAlgorithm()))
	buf = appendLenBytes(buf, []byte(permit.GetSenderAgentId()))
	buf = appendLenBytes(buf, []byte(permit.GetResponderAgentId()))
	buf = appendLenBytes(buf, []byte(permit.GetPartitionId()))
	buf = appendLenBytes(buf, []byte(permit.GetPolicyId()))
	buf = appendUint64(buf, permit.GetMaxBandwidthBps())
	buf = appendUint64(buf, uint64(permit.GetMaxDurationSec()))
	buf = appendUint64(buf, uint64(permit.GetMaxParallel()))

	buf = appendUint64(buf, uint64(len(protocols)))
	for _, p := range protocols {
		buf = appendLenBytes(buf, []byte(p))
	}

	buf = appendUint64(buf, uint64(len(directions)))
	for _, d := range directions {
		buf = appendLenBytes(buf, []byte(d))
	}

	buf = appendUint64(buf, permit.GetAuthorityEpoch())
	buf = appendInt64(buf, permit.GetIssuedAtUnix())
	buf = appendInt64(buf, permit.GetExpiresAtUnix())
	return buf
}

// VerifyPermit validates permit structure, responder/sender/partition identity
// binding, authority epoch fencing, validity window, request parameter ceilings,
// signing key status, and Ed25519 signature.
func VerifyPermit(
	permit *netperfpb.NetperfPermitV1,
	req *netperfpb.OpenSessionRequest,
	peer PeerIdentity,
	localAgentID string,
	localPartitionID string,
	minAuthorityEpoch uint64,
	now time.Time,
	resolver PermitKeyResolver,
) error {
	if permit == nil {
		return ErrPermitRequired
	}
	if permit.GetPermitVersion() != permitVersionV1 ||
		permit.GetAlgorithm() != permitAlgorithmEd ||
		len(permit.GetSignature()) != ed25519.SignatureSize ||
		permit.GetIssuerId() == "" ||
		len(permit.GetIssuerKeyId()) == 0 ||
		permit.GetPermitId() == "" {
		return ErrPermitInvalid
	}

	if permit.GetResponderAgentId() != localAgentID ||
		permit.GetPartitionId() != localPartitionID ||
		permit.GetSenderAgentId() != peer.AgentID ||
		peer.PartitionID != localPartitionID ||
		permit.GetSenderAgentId() == "" ||
		permit.GetSenderAgentId() == permit.GetResponderAgentId() {
		return ErrPermitScopeMismatch
	}

	effectiveMinEpoch := max(uint64(1), minAuthorityEpoch)
	if permit.GetAuthorityEpoch() == 0 || permit.GetAuthorityEpoch() < effectiveMinEpoch {
		return fmt.Errorf("%w: permit epoch %d < min %d",
			ErrPermitEpochFenced, permit.GetAuthorityEpoch(), effectiveMinEpoch)
	}

	pubKey, toleranceNano, err := resolveValidPermitKey(resolver, []byte(permit.GetIssuerId()), permit.GetIssuerKeyId())
	if err != nil {
		return err
	}

	if permit.GetExpiresAtUnix() <= permit.GetIssuedAtUnix() {
		return ErrPermitInvalid
	}
	skewSec := clampClockTolerance(toleranceNano) / int64(time.Second)
	nowUnix := now.Unix()
	if nowUnix+skewSec < permit.GetIssuedAtUnix() {
		return ErrPermitExpired
	}
	if permit.GetExpiresAtUnix() <= nowUnix {
		return ErrPermitExpired
	}

	if req != nil {
		if err := verifyRequestAgainstPermit(req, permit); err != nil {
			return err
		}
	}

	preimage := CanonicalPermitPreimage(permit)
	if !ed25519.Verify(pubKey, preimage, permit.GetSignature()) {
		return ErrPermitSignatureInvalid
	}
	return nil
}

func resolveValidPermitKey(resolver PermitKeyResolver, issuerID, issuerKeyID []byte) (ed25519.PublicKey, int64, error) {
	if resolver == nil {
		return nil, 0, ErrPermitKeyUnavailable
	}
	pubKey, status, toleranceNano, ok := resolver.ResolvePermitKey(issuerID, issuerKeyID)
	if !ok {
		switch status {
		case edgerecord.KeyHistoricallyRevoked:
			return nil, 0, ErrPermitKeyRevoked
		case edgerecord.KeyInvalid:
			return nil, 0, ErrPermitKeyInvalid
		case edgerecord.KeyUnavailable, edgerecord.KeyValid:
			return nil, 0, ErrPermitKeyUnavailable
		default:
			return nil, 0, ErrPermitKeyUnavailable
		}
	}
	switch status {
	case edgerecord.KeyValid:
	case edgerecord.KeyHistoricallyRevoked:
		return nil, 0, ErrPermitKeyRevoked
	case edgerecord.KeyInvalid:
		return nil, 0, ErrPermitKeyInvalid
	case edgerecord.KeyUnavailable:
		return nil, 0, ErrPermitKeyUnavailable
	default:
		return nil, 0, ErrPermitKeyUnavailable
	}
	if len(pubKey) != ed25519.PublicKeySize {
		return nil, 0, ErrPermitKeyInvalid
	}
	return pubKey, toleranceNano, nil
}

func verifyRequestAgainstPermit(req *netperfpb.OpenSessionRequest, permit *netperfpb.NetperfPermitV1) error {
	if _, err := ValidateRequestBounds(req); err != nil {
		return err
	}
	if !slices.Contains(permit.GetAllowedProtocols(), req.GetProtocol()) {
		return fmt.Errorf("%w: protocol %s not permitted", ErrPermitCeilingExceeded, req.GetProtocol().String())
	}
	if !slices.Contains(permit.GetAllowedDirections(), req.GetDirection()) {
		return fmt.Errorf("%w: direction %s not permitted", ErrPermitCeilingExceeded, req.GetDirection().String())
	}
	if req.GetBandwidthBps() > permit.GetMaxBandwidthBps() {
		return fmt.Errorf("%w: bandwidth %d > max %d", ErrPermitCeilingExceeded, req.GetBandwidthBps(), permit.GetMaxBandwidthBps())
	}
	if req.GetDurationSec() > permit.GetMaxDurationSec() {
		return fmt.Errorf("%w: duration %d > max %d", ErrPermitCeilingExceeded, req.GetDurationSec(), permit.GetMaxDurationSec())
	}
	if req.GetParallel() > permit.GetMaxParallel() {
		return fmt.Errorf("%w: parallel %d > max %d", ErrPermitCeilingExceeded, req.GetParallel(), permit.GetMaxParallel())
	}
	return nil
}

func clampClockTolerance(ns int64) int64 {
	if ns < 0 {
		return 0
	}
	if ns > MaxClockToleranceNano {
		return MaxClockToleranceNano
	}
	return ns
}

func normalizePermitProtocols(values []netperfpb.NetperfProtocol) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, v := range values {
		var name string
		switch v {
		case netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP:
			name = "tcp"
		case netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP:
			name = "udp"
		case netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UNSPECIFIED:
			continue
		default:
			continue
		}
		if _, ok := seen[name]; !ok {
			seen[name] = struct{}{}
			out = append(out, name)
		}
	}
	slices.Sort(out)
	return out
}

func normalizePermitDirections(values []netperfpb.NetperfDirection) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, v := range values {
		var name string
		switch v {
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
			name = "upload"
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
			name = "download"
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL:
			name = "bidirectional"
		case netperfpb.NetperfDirection_NETPERF_DIRECTION_UNSPECIFIED:
			continue
		default:
			continue
		}
		if _, ok := seen[name]; !ok {
			seen[name] = struct{}{}
			out = append(out, name)
		}
	}
	slices.Sort(out)
	return out
}

func appendUint64(dst []byte, v uint64) []byte {
	var tmp [8]byte
	binary.BigEndian.PutUint64(tmp[:], v)
	return append(dst, tmp[:]...)
}

func appendInt64(dst []byte, v int64) []byte {
	var tmp [8]byte
	binary.BigEndian.PutUint64(tmp[:], uint64(v))
	return append(dst, tmp[:]...)
}

func appendLenBytes(dst, data []byte) []byte {
	dst = appendUint64(dst, uint64(len(data)))
	return append(dst, data...)
}
