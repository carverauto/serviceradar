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

package edgerecord

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// MaxTrustDocumentBytes bounds the complete authenticated configuration member,
// including the registry member shared with gateway snapshots.
const MaxTrustDocumentBytes = 4 << 20
const maxTrustFences = 10_000
const maxTrustKeys = 256

var ErrTrustDocument = errors.New("edgerecord: invalid authenticated trust document")

type trustDocument struct {
	ClockToleranceNano int64                `json:"clock_tolerance_nano"`
	Keys               []trustDocumentKey   `json:"keys"`
	Fences             []trustDocumentFence `json:"fences"`
	Scopes             []trustDocumentScope `json:"scopes"`
	// Registry authority is consumed by gateways. Parsing this document does not
	// install or authorize contracts: attribution still uses explicit validators.
	Registry json.RawMessage `json:"contract_registry"`
}

type trustDocumentKey struct {
	IssuerID []byte   `json:"issuer_id"`
	KeyID    []byte   `json:"issuer_key_id"`
	Public   []byte   `json:"public_key"`
	Purposes []string `json:"purposes"`
	Status   string   `json:"status"`
}

type trustDocumentFence struct {
	Scope      []byte  `json:"network_scope_id"`
	Assignment []byte  `json:"producer_assignment_id"`
	Shard      *uint32 `json:"run_shard"`
	Epoch      *uint64 `json:"authority_epoch"`
}

type trustDocumentScope struct {
	AgentID string   `json:"agent_id"`
	Scopes  [][]byte `json:"network_scope_ids"`
}

type snapshotKeyID struct{ issuer, key string }
type snapshotFenceID struct {
	scope, assignment string
	shard             uint32
}
type snapshotKey struct {
	public   ed25519.PublicKey
	status   KeyStatus
	purposes map[edgev1.EdgeCapabilityPurpose]bool
}

// TrustSnapshot is one complete immutable RecordTrust document, bound to the
// authenticated configuration recipient. It never merges an older document:
// replacement must preserve exactly the supplied historical key statuses.
// The existing core issuer currently exposes a singleton key; this consumer
// preserves supplied history but does not implement issuer rotation itself.
type TrustSnapshot struct {
	agent     []byte
	epoch     uint64
	tolerance int64
	keys      map[snapshotKeyID]snapshotKey
	fences    map[snapshotFenceID]uint64
	scopes    map[string]bool
}

// ParseTrustDocument accepts only a document received over the authenticated
// agent configuration path. epoch pins the caller's local install transaction;
// it is not a new expiration clock. Existing signed authority windows govern
// freshness. Missing or malformed documents must leave producer work retryable.
func ParseTrustDocument(raw, authenticatedAgent []byte, epoch uint64) (*TrustSnapshot, error) {
	if len(raw) == 0 || len(raw) > MaxTrustDocumentBytes || epoch == 0 || ValidateAuthenticatedPrincipal(authenticatedAgent) != nil {
		return nil, ErrTrustDocument
	}
	var doc trustDocument
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrTrustDocument, err)
	}
	if doc.ClockToleranceNano < 0 || doc.ClockToleranceNano > MaxClockToleranceNano || len(doc.Keys) == 0 || len(doc.Keys) > maxTrustKeys || len(doc.Fences) > maxTrustFences || len(doc.Scopes) > 1 {
		return nil, ErrTrustDocument
	}
	snapshot := &TrustSnapshot{agent: bytes.Clone(authenticatedAgent), epoch: epoch, tolerance: doc.ClockToleranceNano,
		keys: make(map[snapshotKeyID]snapshotKey), fences: make(map[snapshotFenceID]uint64), scopes: make(map[string]bool)}
	if err := snapshot.readScopes(doc.Scopes); err != nil {
		return nil, err
	}
	for _, key := range doc.Keys {
		if err := snapshot.readKey(key); err != nil {
			return nil, err
		}
	}
	for _, fence := range doc.Fences {
		if err := snapshot.readFence(fence); err != nil {
			return nil, err
		}
	}
	return snapshot, nil
}

func (s *TrustSnapshot) readScopes(bindings []trustDocumentScope) error {
	for _, binding := range bindings {
		if binding.AgentID != string(s.agent) || len(binding.Scopes) == 0 || len(binding.Scopes) > maxTrustFences {
			return ErrTrustDocument
		}
		for _, scope := range binding.Scopes {
			if ValidateCanonicalUUID(scope) != nil || s.scopes[string(scope)] {
				return ErrTrustDocument
			}
			s.scopes[string(scope)] = true
		}
	}
	return nil
}

func (s *TrustSnapshot) readKey(key trustDocumentKey) error {
	id := snapshotKeyID{string(key.IssuerID), string(key.KeyID)}
	if len(key.IssuerID) == 0 || len(key.KeyID) == 0 || len(key.Public) != ed25519.PublicKeySize || len(key.Purposes) == 0 || len(key.Purposes) > 3 {
		return ErrTrustDocument
	}
	if _, exists := s.keys[id]; exists {
		return ErrTrustDocument
	}
	parsed := snapshotKey{public: bytes.Clone(key.Public), purposes: make(map[edgev1.EdgeCapabilityPurpose]bool)}
	switch key.Status {
	case "", "valid":
		parsed.status = KeyValid
	case "historically_revoked":
		parsed.status = KeyHistoricallyRevoked
	default:
		return ErrTrustDocument
	}
	for _, purpose := range key.Purposes {
		var value edgev1.EdgeCapabilityPurpose
		switch purpose {
		case "production":
			value = edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION
		case "source":
			value = edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE
		case "delivery":
			value = edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY
		default:
			return ErrTrustDocument
		}
		parsed.purposes[value] = true
	}
	s.keys[id] = parsed
	return nil
}

func (s *TrustSnapshot) readFence(fence trustDocumentFence) error {
	if fence.Shard == nil || fence.Epoch == nil || ValidateCanonicalUUID(fence.Scope) != nil || ValidateCanonicalUUID(fence.Assignment) != nil || !s.scopes[string(fence.Scope)] {
		return ErrTrustDocument
	}
	id := snapshotFenceID{string(fence.Scope), string(fence.Assignment), *fence.Shard}
	if _, exists := s.fences[id]; exists {
		return ErrTrustDocument
	}
	s.fences[id] = *fence.Epoch
	return nil
}

// PolicyFor resolves the exact namespace/assignment/shard fence from this same
// key snapshot. An unavailable fence remains retryable through the existing
// signed validator; no claimed record epoch substitutes for missing authority.
func (s *TrustSnapshot) PolicyFor(record *edgev1.EdgeRecordV1, nowUnixNano int64) (AuthorizationPolicy, error) {
	if s == nil || record == nil || !bytes.Equal(record.GetProducerContext().GetOriginPrincipalId(), s.agent) || !s.scopes[string(record.GetNetworkScopeId())] {
		return AuthorizationPolicy{}, ErrTrustMissing
	}
	producer := record.GetProducerContext()
	policy := AuthorizationPolicy{Trust: s, NowUnixNano: nowUnixNano, ClockToleranceNano: s.tolerance, TrustPolicyEpoch: s.epoch}
	if epoch, exists := s.fences[snapshotFenceID{string(record.GetNetworkScopeId()), string(producer.GetProducerAssignmentId()), producer.GetRunShard()}]; exists {
		policy.ActiveFence = ResolvedFence(epoch)
	}
	return policy, nil
}

func (s *TrustSnapshot) ResolveKey(issuerID, issuerKeyID []byte, evidence KeyEvidence) KeyResolution {
	result := KeyResolution{Status: KeyUnavailable, Purpose: evidence.Purpose}
	if s == nil {
		return result
	}
	result.TrustPolicyEpoch = s.epoch
	if evidence.TrustPolicyEpoch != s.epoch || evidence.TrustPolicyEpoch == 0 {
		return result
	}
	result.Status = KeyInvalid
	key, exists := s.keys[snapshotKeyID{string(issuerID), string(issuerKeyID)}]
	if !exists || !key.purposes[evidence.Purpose] {
		return result
	}
	result.Status, result.Public = key.status, bytes.Clone(key.public)
	return result
}
