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

package spool

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/fairsched"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	"google.golang.org/protobuf/proto"
)

type attributionTrust ed25519.PublicKey

func (k attributionTrust) ResolveKey(_, _ []byte, evidence edgerecord.KeyEvidence) edgerecord.KeyResolution {
	return edgerecord.KeyResolution{Status: edgerecord.KeyValid, Public: ed25519.PublicKey(k), TrustPolicyEpoch: evidence.TrustPolicyEpoch, Purpose: evidence.Purpose}
}

func attributionAppend(t *testing.T, kind string) (AttributedAppend, LaneKey, Identity) {
	return attributionAppendMutated(t, kind, nil)
}

func attributionAppendMutated(t *testing.T, kind string, mutateRecord func(*edgev1.EdgeRecordV1)) (AttributedAppend, LaneKey, Identity) {
	t.Helper()
	name := "sweep_join_positive_scheduled_sweep.bin"
	if kind == "control" {
		name = "version_tombstone_scope_ok.bin"
	}
	if kind == "metrics" {
		name = "record_no_source.bin"
	}
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "proto", "edge", "v1", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	r, err := edgerecord.DecodeRecord(raw)
	if err != nil {
		t.Fatal(err)
	}
	if kind == "metrics" {
		payload, err := proto.Marshal(&metricpb.MetricBatch{SchemaVersion: "serviceradar.metric.v1", IngestIdentity: &metricpb.IngestIdentity{Source: "sysmon-metrics"}, Metrics: []*metricpb.Metric{{Name: "cpu.usage_percent", MetricType: "sysmon.cpu"}}})
		if err != nil {
			t.Fatal(err)
		}
		r.OutputContract.ContractId = "serviceradar.metrics.batch"
		r.OutputContract.ContractVersion = 1
		r.ProductionCapability.GetProduction().ContractId = r.OutputContract.ContractId
		r.ProductionCapability.GetProduction().ContractVersion = 1
		r.Payload = payload
		hash := sha256.Sum256(payload)
		r.PayloadSha256 = hash[:]
		r.EncodedSize = uint32(len(payload))
		r.UncompressedSize = uint32(len(payload))
		r.ProjectedRowCount = 1
		r.ProjectedWriteBytes = 1024
	}
	if mutateRecord != nil {
		mutateRecord(r)
	}
	private := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x63}, 32))
	public := private.Public().(ed25519.PublicKey)
	edgerecord.SignCapability(r.ProductionCapability, private)
	if r.SourceAuthorization != nil {
		edgerecord.SignCapability(r.SourceAuthorization.Capability, private)
	}
	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
	raw, err = edgerecord.CanonicalRecordBytes(r)
	if err != nil {
		t.Fatal(err)
	}
	millis := uint64(r.EventId[0])<<40 | uint64(r.EventId[1])<<32 | uint64(r.EventId[2])<<24 | uint64(r.EventId[3])<<16 | uint64(r.EventId[4])<<8 | uint64(r.EventId[5])
	policy := edgerecord.AuthorizationPolicy{Trust: attributionTrust(public), TrustPolicyEpoch: 1, NowUnixNano: int64(millis) * 1_000_000, ActiveFence: edgerecord.ResolvedFence(r.ProducerContext.GetAuthorityEpoch())}
	var validated edgerecord.ValidatedAttribution
	switch kind {
	case "sweep":
		validated, err = edgerecord.SweepRecoveryAttribution(raw, r.OutputContract, policy)
	case "control":
		validated, err = edgerecord.ControlRecoveryAttribution(raw, r.OutputContract, policy)
	case "metrics":
		validated, err = edgerecord.MetricRecoveryAttribution(raw, policy)
	}
	if err != nil {
		t.Fatal(err)
	}
	return AttributedAppend{EventID: bytes.Clone(r.EventId), Body: raw, Validated: validated}, LaneKey{RouteProfile: r.RouteProfile, TrafficClass: r.TrafficClass}, Identity{NetworkScopeID: r.NetworkScopeId, AgentID: r.ProducerContext.OriginPrincipalId}
}

func openAttributedLanes(t *testing.T, root string, identity Identity, allocator *Allocator, inject func(*Spool)) *LaneSet {
	t.Helper()
	if allocator == nil {
		allocator = attributionAllocator(t)
	}
	control := LaneKey{RouteProfile: recoveryLane.RouteProfile, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	taxonomy, err := fairsched.NewLaneTaxonomy([]fairsched.LanePolicy{{Key: bulkLane, WeightBytes: 1}, {Key: interactiveLane, WeightBytes: 1}, {Key: control, WeightBytes: 1}}, control)
	if err != nil {
		t.Fatal(err)
	}
	ls, err := OpenLanes(root, identity, taxonomy, WithGenerationOptions(func(g GenerationIdentity, _ string) ([]Option, error) {
		opts := []Option{WithAttribution(g)}
		if allocator != nil {
			opts = append(opts, WithAllocator(allocator))
		}
		if inject != nil {
			opts = append(opts, inject)
		}
		return opts, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ls.Close() })
	return ls
}

func TestAttributedAppendRejectsMismatchBeforeAllocation(t *testing.T) {
	input, lane, identity := attributionAppend(t, "sweep")
	root := t.TempDir()
	ls := openAttributedLanes(t, root, identity, nil, nil)
	changed := input
	changed.Body = bytes.Clone(input.Body)
	changed.Body[len(changed.Body)-1] ^= 1
	if _, err := ls.AppendAttributed(lane, identity, changed); !errors.Is(err, ErrPermanent) || !errors.Is(err, edgerecord.ErrAttributionJoin) {
		t.Fatalf("mismatch: %v", err)
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("refusal created a generation: %v %v", entries, err)
	}
	receipt, err := ls.AppendAttributed(lane, identity, input)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Sequence != 1 {
		t.Fatalf("refusal consumed sequence: %d", receipt.Sequence)
	}
	generation, _ := ls.OpenGeneration(lane)
	if _, err := generation.spool.Append(input.EventID, input.Body); !errors.Is(err, ErrAttributionRequired) {
		t.Fatalf("configured bypass: %v", err)
	}
	if generation.NextSequence() != 2 {
		t.Fatal("bypass consumed sequence")
	}
}

func TestAttributionSurvivesRecordCorruption(t *testing.T) {
	for _, kind := range []string{"sweep", "control", "metrics"} {
		t.Run(kind, func(t *testing.T) {
			input, lane, identity := attributionAppend(t, kind)
			root := t.TempDir()
			ls := openAttributedLanes(t, root, identity, nil, nil)
			for range 3 {
				if _, err := ls.AppendAttributed(lane, identity, input); err != nil {
					t.Fatal(err)
				}
			}
			g, _ := ls.OpenGeneration(lane)
			dir := g.dir
			if _, err := g.CommittedAttribution(2); err != nil {
				t.Fatal(err)
			}
			if err := ls.Close(); err != nil {
				t.Fatal(err)
			}
			// Preserve allocation and attribution evidence while every record body is lost.
			if err := os.Truncate(filepath.Join(dir, segmentFile), 0); err != nil {
				t.Fatal(err)
			}
			reopened := openAttributedLanes(t, root, identity, nil, nil)
			g, _ = reopened.OpenGeneration(lane)
			for seq := uint64(1); seq <= 3; seq++ {
				span, err := g.RecoveryClassification(seq)
				if err != nil {
					t.Fatal(err)
				}
				if !proto.Equal(span, attributionSpan(seq, input.Validated.Attribution())) {
					t.Fatalf("slot %d lost attribution: %v", seq, span)
				}
				if _, err := g.CommittedAttribution(seq); !errors.Is(err, ErrCommittedAttribution) {
					t.Fatalf("lost record exposed: %v", err)
				}
			}
			if got, err := g.Unresolved(); err != nil || len(got) != 0 {
				t.Fatalf("corrupt records sent: %v %v", got, err)
			}
		})
	}
}

func TestLaterBindingDamageNeverBecomesWrongAuthority(t *testing.T) {
	for _, damage := range []string{"checksum", "unsupported_version", "scope_substitution"} {
		t.Run(damage, func(t *testing.T) {
			input, lane, identity := attributionAppend(t, "sweep")
			root := t.TempDir()
			ls := openAttributedLanes(t, root, identity, nil, nil)
			if _, err := ls.AppendAttributed(lane, identity, input); err != nil {
				t.Fatal(err)
			}
			g, _ := ls.OpenGeneration(lane)
			proof, err := g.CommittedAttribution(1)
			if err != nil {
				t.Fatal(err)
			}
			dir := g.dir
			if err = ls.Close(); err != nil {
				t.Fatal(err)
			}
			raw, err := os.ReadFile(filepath.Join(dir, attributionFile))
			if err != nil {
				t.Fatal(err)
			}
			want := edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT
			switch damage {
			case "checksum":
				raw[sidecarHeaderSize+82] ^= 1
			case "unsupported_version":
				binary.BigEndian.PutUint64(raw[5:], 2)
				binary.BigEndian.PutUint32(raw[25:], crc32.Checksum(raw[:25], crcTable))
				want = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED
			case "scope_substitution":
				entry := proof.entry
				entry.attribution = proof.Attribution()
				entry.attribution.Identity.ProductionScopeId = testScope(0x29)
				entry.digest, err = edgerecord.LocalBindingDigest(1, entry.coordinates, entry.attribution)
				if err != nil {
					t.Fatal(err)
				}
				raw, err = encodeAttributionEntry(entry)
				if err != nil {
					t.Fatal(err)
				}
			}
			if err = os.WriteFile(filepath.Join(dir, attributionFile), raw, filePerm); err != nil {
				t.Fatal(err)
			}
			if err = os.Truncate(filepath.Join(dir, segmentFile), 0); err != nil {
				t.Fatal(err)
			}
			reopened := openAttributedLanes(t, root, identity, nil, nil)
			g, _ = reopened.OpenGeneration(lane)
			span, err := g.RecoveryClassification(1)
			if err != nil {
				t.Fatal(err)
			}
			if span.GetUnattributable().GetReason() != want {
				t.Fatalf("damage %s produced wrong authority: %v", damage, span)
			}
			if _, err = g.CommittedAttribution(1); !errors.Is(err, ErrCommittedAttribution) {
				t.Fatalf("damaged binding exposed: %v", err)
			}
		})
	}
}

func TestSidecarReadErrorDoesNotBecomeLossClassification(t *testing.T) {
	for _, name := range []string{attributionFile, relocationFile} {
		t.Run(name, func(t *testing.T) {
			input, lane, identity := attributionAppend(t, "sweep")
			ls := openAttributedLanes(t, t.TempDir(), identity, nil, nil)
			if _, err := ls.AppendAttributed(lane, identity, input); err != nil {
				t.Fatal(err)
			}
			g, _ := ls.OpenGeneration(lane)
			path := filepath.Join(g.dir, name)
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				t.Fatal(err)
			}
			// An actual filesystem read failure, not malformed readable contents.
			if err := os.Mkdir(path, dirPerm); err != nil {
				t.Fatal(err)
			}
			if span, err := g.RecoveryClassification(1); !errors.Is(err, syscall.EISDIR) || span != nil {
				t.Fatalf("I/O failure became loss evidence: %v %v", span, err)
			}
			if _, err := g.CommittedAttribution(1); !errors.Is(err, syscall.EISDIR) {
				t.Fatalf("I/O failure became committed evidence: %v", err)
			}
		})
	}
}

func TestAttributionBarrierWithholdsReceiptAndRestartClassifies(t *testing.T) {
	for _, stop := range []barrier{barrierPrepareA, barrierPrepareB, barrierRecord, barrierAttribution, barrierAttributionDir, barrierCommitA, barrierCommitB} {
		t.Run(string(rune('a'+stop)), func(t *testing.T) {
			input, lane, identity := attributionAppend(t, "sweep")
			root := t.TempDir()
			ls := openAttributedLanes(t, root, identity, nil, func(s *Spool) {
				s.beforeBarrier = func(at barrier) error {
					if at == stop {
						return syscall.EIO
					}
					return nil
				}
			})
			receipt, err := ls.AppendAttributed(lane, identity, input)
			if !errors.Is(err, syscall.EIO) || receipt.Sequence != 0 {
				t.Fatalf("receipt crossed failed barrier: %+v %v", receipt, err)
			}
			g, _ := ls.OpenGeneration(lane)
			if _, err = g.spool.CommitAttributed(input); !errors.Is(err, syscall.EIO) {
				t.Fatalf("failed spool appended: %v", err)
			}
			if err = ls.Close(); err != nil {
				t.Fatal(err)
			}
			reopened := openAttributedLanes(t, root, identity, nil, nil)
			g, _ = reopened.OpenGeneration(lane)
			if stop != barrierPrepareA && g.NextSequence() != 2 {
				t.Fatalf("allocated sequence reused: %d", g.NextSequence())
			}
			if _, err = g.CommittedAttribution(1); err == nil {
				t.Fatal("incomplete two-copy commit exposed")
			}
			if stop == barrierCommitA || stop == barrierCommitB {
				span, err := g.RecoveryClassification(1)
				if err != nil {
					t.Fatal(err)
				}
				if !proto.Equal(span, attributionSpan(1, input.Validated.Attribution())) {
					t.Fatalf("durable sidecar lost: %v", span)
				}
			}
		})
	}
}

func TestAttributedRelocationReopensMappingAndRetainsSource(t *testing.T) {
	input, lane, identity := attributionAppend(t, "sweep")
	root := t.TempDir()
	allocator := attributionAllocator(t)
	ls := openAttributedLanes(t, root, identity, allocator, nil)
	first, err := ls.AppendAttributed(lane, identity, input)
	if err != nil {
		t.Fatal(err)
	}
	source, _ := ls.OpenGeneration(lane)
	proof, err := source.CommittedAttribution(first.Sequence)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = ls.Rotate(lane); err != nil {
		t.Fatal(err)
	}
	recoveryID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := ls.CreateRecoveryDestination(lane, recoveryID, 0)
	if err != nil {
		t.Fatal(err)
	}
	grant, err := allocator.AcquireRecovery(destination.dir)
	if err != nil {
		t.Fatal(err)
	}
	usage := allocator.Usage()
	allocator.ChargeMeasured(filepath.Join(root, "other-lane"), usage.OrdinaryCeiling-usage.OrdinaryUsed)
	if _, err = ls.AppendAttributed(lane, identity, input); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("ordinary append crossed reserve floor: %v", err)
	}
	if destination.NextSequence() != 1 {
		t.Fatal("ordinary refusal allocated destination slot")
	}
	copied, err := destination.CommitRelocated(proof, grant)
	if err != nil {
		t.Fatal(err)
	}
	dir := destination.dir
	if _, err = os.Stat(filepath.Join(source.dir, segmentFile)); err != nil {
		t.Fatal("relocation deleted source", err)
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openAttributedLanes(t, root, identity, allocator, nil)
	destination, err = reopened.CreateRecoveryDestination(lane, recoveryID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := allocator.Usage(); got.OrdinaryUsed != usage.OrdinaryCeiling || got.RecoveryUsed == 0 {
		t.Fatalf("reopen lost reserve ownership or charged it twice: %+v", got)
	}
	committed, err := destination.CommittedAttribution(copied.Sequence)
	if err != nil {
		t.Fatal(err)
	}
	old, ok := committed.SourceCoordinates()
	if !ok || !bytes.Equal(old.SpoolGenerationID, first.Generation.SpoolID) || old.Sequence != first.Sequence {
		t.Fatalf("mapping lost: %+v", old)
	}
	if bytes.Equal(committed.BindingDigest(), proof.BindingDigest()) || len(committed.MappingDigest()) != 32 {
		t.Fatal("destination not rebound or mapping not committed")
	}
	if !proto.Equal(attributionSpan(1, committed.Attribution()), attributionSpan(1, proof.Attribution())) {
		t.Fatal("relocation changed authority")
	}
	// A self-checksummed mapping rewrite still cannot replace what v2 committed.
	raw, err := os.ReadFile(filepath.Join(dir, relocationFile))
	if err != nil {
		t.Fatal(err)
	}
	payload, state := decodeSidecar(raw, relocationMagic, copied.Sequence)
	if state != AttributionVerifies {
		t.Fatal(state)
	}
	mapping, err := decodeRelocation(payload)
	if err != nil {
		t.Fatal(err)
	}
	mapping.sourceSequence++
	forged, err := encodeSidecar(relocationMagic, 1, copied.Sequence, mapping.encode())
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, relocationFile), forged, filePerm); err != nil {
		t.Fatal(err)
	}
	if _, err = destination.CommittedAttribution(copied.Sequence); !errors.Is(err, ErrCommittedAttribution) {
		t.Fatalf("forged mapping authorized: %v", err)
	}
}

func TestAttributedReclaimPreservesAccountingAndSequence(t *testing.T) {
	input, lane, identity := attributionAppend(t, "sweep")
	root := t.TempDir()
	allocator := attributionAllocator(t)
	ls := openAttributedLanes(t, root, identity, allocator, nil)
	for cycle := uint64(1); cycle <= 2; cycle++ {
		receipt, err := ls.AppendAttributed(lane, identity, input)
		if err != nil || receipt.Sequence != cycle {
			t.Fatalf("append after reclaim: %+v %v", receipt, err)
		}
		g, _ := ls.OpenGeneration(lane)
		if _, err = g.CommittedAttribution(cycle); err != nil {
			t.Fatal(err)
		}
		before, err := g.spool.laneBytes()
		if err != nil {
			t.Fatal(err)
		}
		if got := allocator.Usage().OrdinaryUsed; got != before+terminalEvidenceAllowance {
			t.Fatalf("sidecar charge: got %d want %d", got, before+terminalEvidenceAllowance)
		}
		ack, err := proto.Marshal(&edgev1.EdgeDeliveryAckV1{SpoolId: g.Identity().SpoolID, SessionNonce: evid(92), ResolvedThroughSequence: cycle,
			Dispositions: []*edgev1.EdgeRecordDisposition{{Sequence: cycle, EventId: input.EventID, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}}})
		if err != nil {
			t.Fatal(err)
		}
		if err = g.spool.ResolveWithEvidence(cycle, ack); err != nil {
			t.Fatal(err)
		}
		if g.spool.baseSeq != cycle {
			t.Fatal("terminal evidence did not reclaim")
		}
		if _, err = os.Stat(filepath.Join(g.dir, attributionFile)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("obsolete sidecar retained: %v", err)
		}
		after, err := g.spool.laneBytes()
		if err != nil || after >= before || allocator.Usage().OrdinaryUsed != after {
			t.Fatalf("reclaimed bytes remain charged: before=%d after=%d usage=%+v err=%v", before, after, allocator.Usage(), err)
		}
		if err = ls.Close(); err != nil {
			t.Fatal(err)
		}
		ls = openAttributedLanes(t, root, identity, allocator, nil)
		g, _ = ls.OpenGeneration(lane)
		if g.NextSequence() != cycle+1 || allocator.Usage().OrdinaryUsed != after {
			t.Fatal("restart changed sequence or byte ownership")
		}
	}
}

func TestRelocationBarrierRetainsSourceAndWithholdsWitness(t *testing.T) {
	for name, stop := range map[string]barrier{"mapping": barrierRelocation, "mapping_directory": barrierRelocationDir, "commit_a": barrierCommitA, "commit_b": barrierCommitB} {
		t.Run(name, func(t *testing.T) {
			input, lane, identity := attributionAppend(t, "sweep")
			root := t.TempDir()
			allocator := attributionAllocator(t)
			ls := openAttributedLanes(t, root, identity, allocator, nil)
			if _, err := ls.AppendAttributed(lane, identity, input); err != nil {
				t.Fatal(err)
			}
			source, _ := ls.OpenGeneration(lane)
			proof, err := source.CommittedAttribution(1)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = ls.Rotate(lane); err != nil {
				t.Fatal(err)
			}
			recoveryID, err := edgerecord.NewUUIDv7()
			if err != nil {
				t.Fatal(err)
			}
			destination, err := ls.CreateRecoveryDestination(lane, recoveryID, 0)
			if err != nil {
				t.Fatal(err)
			}
			destination.spool.beforeBarrier = func(at barrier) error {
				if at == stop {
					return syscall.EIO
				}
				return nil
			}
			grant, err := allocator.AcquireRecovery(destination.dir)
			if err != nil {
				t.Fatal(err)
			}
			receipt, err := destination.CommitRelocated(proof, grant)
			if !errors.Is(err, syscall.EIO) || receipt.Sequence != 0 || !errors.Is(allocator.Err(), syscall.EIO) {
				t.Fatalf("failed relocation produced receipt or stayed writable: %+v %v allocator=%v", receipt, err, allocator.Err())
			}
			if err = ls.Close(); err != nil {
				t.Fatal(err)
			}
			ls = openAttributedLanes(t, root, identity, nil, nil)
			destination, err = ls.CreateRecoveryDestination(lane, recoveryID, 0)
			if err != nil {
				t.Fatal(err)
			}
			if destination.NextSequence() != 2 {
				t.Fatal("restart reused interrupted destination sequence")
			}
			if _, err = destination.CommittedAttribution(1); !errors.Is(err, ErrCommittedAttribution) {
				t.Fatalf("incomplete relocation exposed: %v", err)
			}
			retained := ls.Generations(lane)[0]
			if _, err = retained.CommittedAttribution(1); err != nil {
				t.Fatalf("source lost after failed relocation: %v", err)
			}
		})
	}
}

func TestAttributionAccountingSurvivesRestart(t *testing.T) {
	for _, limit := range []string{"keys", "runs"} {
		t.Run(limit, func(t *testing.T) {
			input, lane, identity := attributionAppend(t, "sweep")
			root := t.TempDir()
			configure := func(s *Spool) {
				s.segBounds.limits = segmentLimits{maxKeys: 8, maxRuns: 8, maxManifestBytes: 1 << 20}
				if limit == "keys" {
					s.segBounds.limits.maxKeys = 1
				} else {
					s.segBounds.limits.maxRuns = 1
				}
			}
			ls := openAttributedLanes(t, root, identity, nil, configure)
			for range 2 {
				if _, err := ls.AppendAttributed(lane, identity, input); err != nil {
					t.Fatal("same body consumed a distinct key", err)
				}
			}
			if err := ls.Close(); err != nil {
				t.Fatal(err)
			}
			ls = openAttributedLanes(t, root, identity, nil, configure)
			if _, err := ls.AppendAttributed(lane, identity, input); err != nil {
				t.Fatal("reopen changed attribution key", err)
			}
			g, _ := ls.OpenGeneration(lane)
			if len(g.spool.segBounds.keys) != 1 || g.spool.segBounds.runs != 1 {
				t.Fatalf("wrong accounting: %+v", g.spool.segBounds)
			}
			changed, _, _ := attributionAppendMutated(t, "sweep", func(r *edgev1.EdgeRecordV1) {
				r.ProducerContext.ScopeId = testScope(0x44)
				r.ProductionCapability.GetProduction().ScopeId = bytes.Clone(r.ProducerContext.ScopeId)
			})
			if _, err := ls.AppendAttributed(lane, identity, changed); !errors.Is(err, ErrRotationRequired) {
				t.Fatalf("changed complete body did not consume %s: %v", limit, err)
			}
			if g.NextSequence() != 4 {
				t.Fatal("rotation refusal consumed slot")
			}
		})
	}
}

func TestLegacyGenerationDrainsWithoutInventedAttribution(t *testing.T) {
	input, lane, identity := attributionAppend(t, "sweep")
	root := t.TempDir()
	legacy := openLanesWith(t, root, identity, deploymentTaxonomy(t))
	receipt, err := legacy.Append(lane, identity, input.EventID, input.Body)
	if err != nil {
		t.Fatal(err)
	}
	if err = legacy.Close(); err != nil {
		t.Fatal(err)
	}
	current := openAttributedLanes(t, root, identity, nil, nil)
	g, _ := current.OpenGeneration(lane)
	records, err := g.Unresolved()
	if err != nil || len(records) != 1 || !bytes.Equal(records[0].Body, input.Body) {
		t.Fatalf("readable legacy record lost: %v %v", records, err)
	}
	if !bytes.Equal(g.Identity().SpoolID, receipt.Generation.SpoolID) {
		t.Fatal("legacy identity changed")
	}
	if _, err = g.CommittedAttribution(1); !errors.Is(err, ErrCommittedAttribution) {
		t.Fatalf("unbound legacy record became relocation authority: %v", err)
	}
	if _, err = current.AppendAttributed(lane, identity, input); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("legacy evidence width changed: %v", err)
	}
	if _, err = current.Rotate(lane); err != nil {
		t.Fatal(err)
	}
	if _, err = current.AppendAttributed(lane, identity, input); err != nil {
		t.Fatal(err)
	}
	g, _ = current.OpenGeneration(lane)
	if _, err = g.CommittedAttribution(1); err != nil {
		t.Fatal(err)
	}
	old := current.Generations(lane)[0]
	records, err = old.Unresolved()
	if err != nil || len(records) != 1 {
		t.Fatalf("rotation discarded legacy source: %v %v", records, err)
	}
}

func attributionAllocator(t *testing.T) *Allocator {
	t.Helper()
	a, err := NewAllocator(AllocatorConfig{Capacity: 16 << 20, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: Footprint{DestinationSegment: 1 << 20, AttributionSidecar: 1 << 20, JournalCopy: 1 << 20, ManifestPages: 256 << 10, Mapping: 1 << 20, FilesystemMetadata: 4096}})
	if err != nil {
		t.Fatal(err)
	}
	return a
}

// The reserve bounds complete relocation, including storage evidence and both
// sidecars, even when a large generation contains only one attribution key.
func TestAttributedGenerationFitsFullRelocationReserve(t *testing.T) {
	input, lane, identity := attributionAppendMutated(t, "metrics", func(r *edgev1.EdgeRecordV1) {
		var batch metricpb.MetricBatch
		if err := proto.Unmarshal(r.Payload, &batch); err != nil {
			t.Fatal(err)
		}
		batch.Metrics[0].Points = []*metricpb.MetricPoint{{RawValue: strings.Repeat("7", 32<<10), RawValueType: metricpb.MetricValueType_METRIC_VALUE_TYPE_STRING}}
		payload, err := proto.Marshal(&batch)
		if err != nil {
			t.Fatal(err)
		}
		r.Payload = payload
		hash := sha256.Sum256(payload)
		r.PayloadSha256 = hash[:]
		r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
		r.ProjectedWriteBytes = uint64(len(payload))
		r.ProductionCapability.GetProduction().MaxProjectedWriteBytes = r.ProjectedWriteBytes
	})
	for _, bound := range []string{"destination", "sidecars"} {
		t.Run(bound, func(t *testing.T) {
			footprint := Footprint{DestinationSegment: 1 << 20, AttributionSidecar: 1 << 20, JournalCopy: 1 << 20, ManifestPages: 256 << 10, Mapping: 1 << 20, FilesystemMetadata: 4096}
			if bound == "destination" {
				footprint.DestinationSegment = recoveryGenerationFixedBytes + 2*uint64(minRecordLen+len(input.Body)+4*evidenceEntryLen2+terminalEvidenceAllowance)
			}
			if bound == "sidecars" {
				footprint.AttributionSidecar = 4 * sidecarSlotSize
			}
			allocator, err := NewAllocator(AllocatorConfig{Capacity: 16 << 20, MinFree: 4096, MaxConcurrentRecoveries: 1, Recovery: footprint})
			if err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			lanes := openAttributedLanes(t, root, identity, allocator, nil)
			for i := 0; i < 2; i++ {
				if _, err = lanes.AppendAttributed(lane, identity, input); err != nil {
					t.Fatal(err)
				}
			}
			source, _ := lanes.OpenGeneration(lane)
			before := allocator.Usage()
			if _, err = lanes.AppendAttributed(lane, identity, input); !errors.Is(err, ErrRotationRequired) || !errors.Is(err, ErrRetryable) {
				t.Fatalf("full-copy capacity must rotate: %v", err)
			}
			if source.NextSequence() != 3 || allocator.Usage() != before {
				t.Fatal("refused append allocated or charged bytes")
			}
			proofs := make([]CommittedAttribution, 2)
			for i := range proofs {
				proofs[i], err = source.CommittedAttribution(uint64(i + 1))
				if err != nil {
					t.Fatal(err)
				}
			}
			if _, err = lanes.Rotate(lane); err != nil {
				t.Fatal(err)
			}
			recoveryID, err := edgerecord.NewUUIDv7()
			if err != nil {
				t.Fatal(err)
			}
			destination, err := lanes.CreateRecoveryDestination(lane, recoveryID, 0)
			if err != nil {
				t.Fatal(err)
			}
			grant, err := allocator.AcquireRecovery(destination.dir)
			if err != nil {
				t.Fatal(err)
			}
			usage := allocator.Usage()
			allocator.ChargeMeasured(filepath.Join(root, "synthetic-full-lane"), usage.OrdinaryCeiling-usage.OrdinaryUsed)
			if _, err = lanes.AppendAttributed(lane, identity, input); !errors.Is(err, ErrAdmissionRefused) {
				t.Fatalf("ordinary reserve bypass: %v", err)
			}
			for _, proof := range proofs {
				if _, err = destination.CommitRelocated(proof, grant); err != nil {
					t.Fatal(err)
				}
			}
			for seq := uint64(1); seq <= 2; seq++ {
				if _, err = destination.CommittedAttribution(seq); err != nil {
					t.Fatal(err)
				}
			}
			if _, err = os.Stat(filepath.Join(source.dir, segmentFile)); err != nil {
				t.Fatal("relocation removed unproven source", err)
			}
		})
	}
}

func TestAttributedAppendDefersInvalidRecoveryCapacity(t *testing.T) {
	input, lane, identity := attributionAppend(t, "sweep")
	for _, invalid := range []string{"missing allocator", "record exceeds empty generation"} {
		t.Run(invalid, func(t *testing.T) {
			root := t.TempDir()
			allocator, err := NewAllocator(AllocatorConfig{Capacity: 16 << 20, MinFree: 4096, MaxConcurrentRecoveries: 1,
				Recovery: Footprint{DestinationSegment: recoveryGenerationFixedBytes + uint64(minRecordLen+len(input.Body)+4*evidenceEntryLen2+terminalEvidenceAllowance) - 1,
					AttributionSidecar: 1 << 20, JournalCopy: 1 << 20, ManifestPages: 256 << 10, Mapping: 1 << 20, FilesystemMetadata: 4096}})
			if err != nil {
				t.Fatal(err)
			}
			lanes := openAttributedLanes(t, root, identity, allocator, func(s *Spool) {
				if invalid == "missing allocator" {
					s.alloc = nil
				}
			})
			if _, err := lanes.AppendAttributed(lane, identity, input); !errors.Is(err, ErrInvalidAllocatorConfig) || !errors.Is(err, ErrAdmissionRefused) || errors.Is(err, ErrPermanent) || errors.Is(err, ErrRotationRequired) {
				t.Fatalf("unbounded attributed append or wrong retry policy: %v", err)
			}
			g, _ := lanes.OpenGeneration(lane)
			if g.NextSequence() != 1 {
				t.Fatal("invalid capacity allocated sequence")
			}
			if err := lanes.Close(); err != nil {
				t.Fatal(err)
			}
			corrected := openAttributedLanes(t, root, identity, nil, nil)
			receipt, err := corrected.AppendAttributed(lane, identity, input)
			if err != nil || receipt.Sequence != 1 {
				t.Fatalf("same event did not retry after settings correction: %+v %v", receipt, err)
			}
			g, _ = corrected.OpenGeneration(lane)
			witness, err := g.CommittedAttribution(1)
			if err != nil || !bytes.Equal(witness.record.Body, input.Body) || !bytes.Equal(witness.record.EventID, input.EventID) {
				t.Fatalf("retry changed input: %v", err)
			}
		})
	}
}

func TestRecoveryControlsShareGrantAndRestoreOwnership(t *testing.T) {
	input, controlKey, identity := attributionAppend(t, "control")
	root := t.TempDir()
	allocator := attributionAllocator(t)
	lanes := openAttributedLanes(t, root, identity, allocator, nil)
	if _, err := lanes.Rotate(bulkLane); err != nil {
		t.Fatal(err)
	}
	destination, _ := lanes.OpenGeneration(bulkLane)
	if _, err := lanes.Rotate(controlKey); err != nil {
		t.Fatal(err)
	}
	control, _ := lanes.OpenGeneration(controlKey)
	grant, err := allocator.AcquireRecovery(destination.dir)
	if err != nil {
		t.Fatal(err)
	}
	if err = grant.AttachControlLane(control); err != nil {
		t.Fatal(err)
	}
	if _, err = allocator.AcquireRecovery(control.dir); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("second grant control: %v", err)
	}
	usage := allocator.Usage()
	allocator.ChargeMeasured(filepath.Join(root, "synthetic-full-lane"), usage.OrdinaryCeiling-usage.OrdinaryUsed)
	if _, err = lanes.AppendAttributed(controlKey, identity, input); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("ordinary control bypass: %v", err)
	}
	receipt, err := control.spool.CommitRecoveryControl(input, grant)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Sequence != 1 || allocator.Usage().ActiveRecoveries != 1 {
		t.Fatal("control consumed another grant or sequence")
	}
	if _, err = control.CommittedAttribution(1); err != nil {
		t.Fatal(err)
	}
	if grant.Used(ArtifactDestinationSegment) != 0 || grant.Used(ArtifactAttributionSidecar) != 0 || grant.Used(ArtifactManifestPages) == 0 {
		t.Fatal("control consumed copy destination footprint")
	}
	if err = lanes.Close(); err != nil {
		t.Fatal(err)
	}
	lanes = openAttributedLanes(t, root, identity, allocator, nil)
	control, _ = lanes.OpenGeneration(controlKey)
	if allocator.Usage().OrdinaryUsed != usage.OrdinaryCeiling {
		t.Fatal("reopen double charged recovery controls")
	}
	if err = lanes.Close(); err != nil {
		t.Fatal(err)
	}
	fresh := attributionAllocator(t)
	inventory := []RecoveryArtifact{}
	var held uint64 = terminalEvidenceAllowance
	for _, path := range []string{filepath.Join(control.dir, segmentFile), filepath.Join(control.dir, attributionFile), control.spool.evidencePath(copyA), control.spool.evidencePath(copyB)} {
		inventory = append(inventory, RecoveryArtifact{ArtifactManifestPages, path})
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		held += uint64(info.Size())
	}
	restored, err := fresh.ResumeRecoveryWithControls(destination.dir, []RecoveryControlInventory{{Directory: control.dir, TerminalSlots: 1}}, inventory, 0)
	if err != nil {
		t.Fatal(err)
	}
	reopened := openAttributedLanes(t, root, identity, fresh, nil)
	control, _ = reopened.OpenGeneration(controlKey)
	if got := fresh.Usage(); got.OrdinaryUsed != usage.OrdinaryUsed || got.ActiveRecoveries != 1 {
		t.Fatalf("control restore ownership: %+v", got)
	}

	if err = restored.Finish(); err != nil {
		t.Fatal(err)
	}
	if err = restored.ReleaseSource(destination.dir, 0); err != nil {
		t.Fatal(err)
	}
	if fresh.Usage().OrdinaryUsed != usage.OrdinaryUsed {
		t.Fatal("source release transferred control ownership early")
	}
	if err = restored.ReleaseArtifacts(); err != nil {
		t.Fatal(err)
	}
	if got := fresh.Usage(); got.ActiveRecoveries != 0 || got.OrdinaryUsed != usage.OrdinaryUsed+held {
		t.Fatalf("control ownership not retained after grant release: %+v", got)
	}
	if _, err = control.CommittedAttribution(1); err != nil {
		t.Fatal("release lost control", err)
	}
}
