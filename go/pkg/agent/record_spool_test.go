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

package agent

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"
)

func openTestRecordSpool(t *testing.T, dir string, opts ...spool.Option) (*RecordSpool, error) {
	t.Helper()
	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: spool.DefaultRecoveryFootprint()})
	if err != nil {
		return nil, err
	}
	return OpenRecordSpool(dir, allocator, opts...)
}

// Test readers preserve each stored record; assertions needing a sequence use
// a single-generation fixture. No production facade flattens sequence numbers.
func (s *RecordSpool) Unresolved() ([]spool.Record, error) {
	var out []spool.Record
	var cursor RecordSpoolCursor
	for {
		source, ok := s.NextSource(&cursor)
		if !ok {
			break
		}
		err := source.Source.ScanFrom(0, func(r spool.Record) bool { out = append(out, r); return true })
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

func testIssuerPrivateKey() ed25519.PrivateKey {
	return ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x64}, ed25519.SeedSize))
}

// Fixture grants are signed after each test has chosen its semantic operands.
// The matching complete policy is installed through the production parser.
func installTestEdgeGrants(t *testing.T, p *PushLoop, agent string, entries []*proto.EdgeOutputGrant, now time.Time) []error {
	t.Helper()
	var scopes [][]byte
	var fences []map[string]any
	var keys []map[string]any
	seenScopes := map[string]bool{}
	seenFences := map[string]bool{}
	seenKeys := map[string]bool{}
	for _, entry := range entries {
		var cap edgev1.EdgeSignedCapabilityV1
		require.NoError(t, gproto.Unmarshal(entry.ProductionCapability, &cap))
		edgerecord.SignCapability(&cap, testIssuerPrivateKey())
		raw, err := gproto.Marshal(&cap)
		require.NoError(t, err)
		entry.ProductionCapability = raw
		claims := cap.GetProduction()
		if !seenScopes[string(claims.NetworkScopeId)] {
			scopes = append(scopes, claims.NetworkScopeId)
			seenScopes[string(claims.NetworkScopeId)] = true
		}
		fenceID := fmt.Sprintf("%x/%x/%d", claims.NetworkScopeId, claims.ProducerAssignmentId, claims.RunShard)
		if !seenFences[fenceID] {
			fences = append(fences, map[string]any{"network_scope_id": claims.NetworkScopeId, "producer_assignment_id": claims.ProducerAssignmentId, "run_shard": claims.RunShard, "authority_epoch": claims.AuthorityEpoch})
			seenFences[fenceID] = true
		}
		keyID := string(cap.IssuerId) + "/" + string(cap.IssuerKeyId)
		if !seenKeys[keyID] {
			keys = append(keys, map[string]any{"issuer_id": cap.IssuerId, "issuer_key_id": cap.IssuerKeyId, "public_key": []byte(testIssuerPrivateKey().Public().(ed25519.PublicKey)), "purposes": []string{"production", "source", "delivery"}, "status": "valid"})
			seenKeys[keyID] = true
		}
	}
	if len(entries) > 0 {
		raw, err := json.Marshal(map[string]any{"keys": keys, "fences": fences, "scopes": []any{map[string]any{"agent_id": agent, "network_scope_ids": scopes}}})
		require.NoError(t, err)
		snapshot, err := edgerecord.ParseTrustDocument(raw, []byte(agent), 1)
		require.NoError(t, err)
		p.edgeRecordTrust.Store(snapshot)
	}
	for _, app := range []edgeMetricsAppender{p.edgeMetricsSpool, p.edgeDiscoverySpool, p.edgeTelemetrySpool, p.edgePluginResultSpool} {
		if setter, ok := app.(interface {
			SetTrustProvider(func() *edgerecord.TrustSnapshot)
		}); ok {
			setter.SetTrustProvider(p.EdgeRecordTrustSnapshot)
		}
	}
	return p.edgeOutputGrants.replace(agent, entries, now)
}

func soleTestGeneration(t *testing.T, s *RecordSpool) *spool.Generation {
	t.Helper()
	var found []*spool.Generation
	for _, key := range s.lanes.Lanes() {
		found = append(found, s.lanes.Generations(key)...)
	}
	require.Len(t, found, 1)
	return found[0]
}

func installTestCapability(t *testing.T, app edgeMetricsAppender, cap *edgev1.EdgeSignedCapabilityV1) {
	t.Helper()
	raw, err := gproto.Marshal(cap)
	require.NoError(t, err)
	claims := cap.GetProduction()
	entry := &proto.EdgeOutputGrant{ContractId: claims.GetContractId(), ContractVersion: claims.GetContractVersion(), ProductionCapability: raw}
	loop := &PushLoop{}
	installTestEdgeGrants(t, loop, string(claims.GetOriginPrincipalId()), []*proto.EdgeOutputGrant{entry}, time.Now())
	require.NoError(t, gproto.Unmarshal(entry.ProductionCapability, cap))
	setter, ok := app.(interface {
		SetTrustProvider(func() *edgerecord.TrustSnapshot)
	})
	require.True(t, ok)
	setter.SetTrustProvider(loop.EdgeRecordTrustSnapshot)
}

func installTestSweep(t *testing.T, sp *RecordSpool, lease *edgev1.SweepLeaseV1) {
	t.Helper()
	cap := lease.ProductionCapability
	for _, slot := range lease.Slots {
		for _, source := range slot.SourceAuthorizations {
			source.Capability.IssuerId = bytes.Clone(cap.IssuerId)
			source.Capability.IssuerKeyId = bytes.Clone(cap.IssuerKeyId)
			edgerecord.SignCapability(source.Capability, testIssuerPrivateKey())
		}
	}
	installTestCapability(t, sp, cap)
}

// The facade owns construction/admission retries: a changed trust snapshot must
// neither rewrite an already sealed record nor authorize an unsealed replacement.
func TestPreparedRecordSurvivesTrustWithdrawalAndAutomaticRotation(t *testing.T) {
	footprint := spool.DefaultRecoveryFootprint()
	footprint.DestinationSegment = 8 << 10
	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: footprint})
	require.NoError(t, err)
	dir := t.TempDir()
	store, err := OpenRecordSpool(dir, allocator)
	require.NoError(t, err)
	t.Cleanup(func() { _ = store.Close() })
	loop, _ := sysmonEdgeLoop(t, store)
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
	batch, err := buildSysmonMetricBatch(syntheticSysmonSamples(1), loop.metricEnvelopeContext())
	require.NoError(t, err)
	built, err := metricsEdgeRecord(batch, loop.currentEdgeOutputGrant(edgerecord.MetricsBatchContractID, time.Now()), 100)
	require.NoError(t, err)
	raw, err := edgerecord.CanonicalRecordBytes(built.record)
	require.NoError(t, err)
	prepared, err := store.PrepareRecord(raw)
	require.NoError(t, err)
	loop.edgeRecordTrust.Store(nil)
	_, err = store.PrepareRecord(raw)
	require.ErrorIs(t, err, edgerecord.ErrTrustMissing)
	first, err := store.AppendPrepared("synthetic", prepared)
	require.NoError(t, err)
	var rotated spool.Receipt
	for i := 0; i < 16; i++ {
		receipt, err := store.AppendPrepared("synthetic", prepared)
		require.NoError(t, err)
		if !bytes.Equal(first.Generation.SpoolID, receipt.Generation.SpoolID) {
			rotated = receipt
			break
		}
	}
	require.NotEmpty(t, rotated.Generation.SpoolID, "bounded generation must rotate automatically")
	require.Equal(t, uint64(1), rotated.Sequence)
	for _, generation := range store.Lanes().Generations(first.Generation.Lane) {
		require.NoError(t, generation.ScanFrom(0, func(record spool.Record) bool {
			require.Equal(t, raw, record.Body)
			require.Equal(t, built.record.EventId, record.EventID)
			_, err := generation.CommittedAttribution(record.Sequence)
			require.NoError(t, err)
			return true
		}))
	}
	changed := *prepared
	changed.Body = bytes.Clone(prepared.Body)
	changed.Body[len(changed.Body)-1] ^= 1
	_, err = store.AppendPrepared("synthetic", &changed)
	require.Error(t, err)
}
