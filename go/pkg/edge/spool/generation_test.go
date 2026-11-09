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
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func retainedRecoveryGeneration(t *testing.T, ls *LaneSet, key LaneKey, id []byte, attempt uint32) *Generation {
	t.Helper()
	var ordinal uint64
	for {
		page := ls.GenerationsPage(key, ordinal, MaxGenerationPage)
		if len(page) == 0 {
			t.Fatal("retained recovery generation missing")
		}
		for _, g := range page {
			if bytes.Equal(g.RecoveryID(), id) && g.RecoveryAttempt() == attempt {
				return g
			}
		}
		ordinal = page[len(page)-1].Identity().Ordinal
	}
}

func closedRecoverySource(t *testing.T, ls *LaneSet, key LaneKey, identity Identity, input AttributedAppend) *Generation {
	t.Helper()
	if _, err := ls.AppendAttributed(key, identity, input); err != nil {
		t.Fatal(err)
	}
	source, _ := ls.OpenGeneration(key)
	if _, err := ls.Rotate(key); err != nil {
		t.Fatal(err)
	}
	return source
}

func TestRecoveryDestinationRemainsSeparateAcrossRestart(t *testing.T) {
	root := t.TempDir()
	input, key, identity := attributionAppend(t, "metrics")
	allocator := recoveryOperationAllocator(t)
	ls := openAttributedLanes(t, root, identity, allocator, nil)
	source := closedRecoverySource(t, ls, key, identity, input)
	recoveryID := recoveryUUID(74)
	destination, grant, err := ls.BeginRecoveryDestination(source, recoveryID, 0, allocator)
	if err != nil {
		t.Fatal(err)
	}
	if producer, ok := ls.OpenGeneration(key); ok && producer == destination {
		t.Fatal("recovery destination became producer generation")
	}
	first, err := ls.AppendAttributed(key, identity, input)
	if err != nil || bytes.Equal(first.Generation.SpoolID, destination.Identity().SpoolID) {
		t.Fatalf("production appended into recovery destination: %v", err)
	}
	controlKey := LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	other, err := ls.CreateRecoveryControlDestination(controlKey, recoveryID, 1, grant)
	if err != nil {
		t.Fatal(err)
	}
	original := destination.Identity()
	recoveryIDCopy := destination.RecoveryID()
	recoveryIDCopy[0] ^= 1
	if !bytes.Equal(destination.RecoveryID(), recoveryID) {
		t.Fatal("caller changed destination operation")
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	allocator = recoveryOperationAllocator(t)
	ls = openAttributedLanes(t, root, identity, allocator, nil)
	source = ls.Generations(key)[0]
	destination, _, err = ls.BeginRecoveryDestination(source, recoveryID, 0, allocator)
	if !errors.Is(err, ErrRecoveryResumeRequired) || !bytes.Equal(destination.Identity().SpoolID, original.SpoolID) {
		t.Fatalf("retained destination acquired a fresh grant: %v", err)
	}
	resumedAttempt := retainedRecoveryGeneration(t, ls, controlKey, recoveryID, 1)
	if !bytes.Equal(resumedAttempt.Identity().SpoolID, other.Identity().SpoolID) {
		t.Fatal("control attempt identity changed")
	}
	if len(ls.Generations(key)) != 3 || len(ls.Generations(controlKey)) != 1 {
		t.Fatal("inventory created another generation")
	}
	if err = destination.SealRecoveryDestination(); err != nil {
		t.Fatal(err)
	}
	if _, err = destination.CommitRelocated(CommittedAttribution{}, nil); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("sealed destination writable: %v", err)
	}
	producer, _ := ls.OpenGeneration(key)
	if _, err = producer.CommitRelocated(CommittedAttribution{}, nil); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("producer accepted relocation: %v", err)
	}
	second, err := ls.AppendAttributed(key, identity, input)
	if err != nil || second.Sequence != 2 || !bytes.Equal(second.Generation.SpoolID, first.Generation.SpoolID) {
		t.Fatalf("destination affected producer: %+v %v", second, err)
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(filepath.Join(other.Directory(), recoveryDestinationFile)); err != nil {
		t.Fatal(err)
	}
	if reopened, err := OpenLanes(root, identity, deploymentTaxonomy(t), WithGenerationOptions(func(id GenerationIdentity, _ string) ([]Option, error) {
		return []Option{WithAttribution(id), WithAllocator(allocator)}, nil
	})); !errors.Is(err, ErrCorruptGeneration) {
		if reopened != nil {
			_ = reopened.Close()
		}
		t.Fatalf("missing recovery marker did not fail inventory: %v", err)
	}
}

func TestClosedGenerationDrainsWithTerminalEvidence(t *testing.T) {
	input, lane, identity := attributionAppend(t, "sweep")
	root := t.TempDir()
	allocator := attributionAllocator(t)
	ls := openAttributedLanes(t, root, identity, allocator, nil)
	receipt, err := ls.AppendAttributed(lane, identity, input)
	if err != nil {
		t.Fatal(err)
	}
	source, _ := ls.OpenGeneration(lane)
	if _, err = ls.Rotate(lane); err != nil {
		t.Fatal(err)
	}
	if !source.Closed() || source.spool.seg != nil {
		t.Fatal("rotation retained descriptor or append authority")
	}
	before := allocator.Usage().OrdinaryUsed
	health, err := source.Health(time.Now())
	if err != nil || health.UnresolvedCount != 1 {
		t.Fatalf("closed generation omitted from health: %+v %v", health, err)
	}
	records, err := source.Unresolved()
	if err != nil || len(records) != 1 || !bytes.Equal(records[0].Body, input.Body) {
		t.Fatalf("closed sender cannot drain: %v", err)
	}
	ack, err := proto.Marshal(&edgev1.EdgeDeliveryAckV1{SpoolId: receipt.Generation.SpoolID, SessionNonce: evid(61), ResolvedThroughSequence: 1,
		Dispositions: []*edgev1.EdgeRecordDisposition{{Sequence: 1, EventId: input.EventID, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}}})
	if err != nil {
		t.Fatal(err)
	}
	if err = source.ResolveWithEvidence(1, ack); err != nil {
		t.Fatal(err)
	}
	if source.Resolved() != 1 || source.spool.baseSeq != 1 || source.spool.seg != nil {
		t.Fatal("closed acknowledgement did not reclaim and release descriptor")
	}
	if allocator.Usage().OrdinaryUsed >= before {
		t.Fatal("closed generation retained reclaimed byte charge")
	}
	if err = source.ReclaimResolved(); err != nil {
		t.Fatal(err)
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	ls = openAttributedLanes(t, root, identity, allocator, nil)
	source = ls.Generations(lane)[0]
	if source.Resolved() != 1 || !source.Closed() || source.spool.seg != nil {
		t.Fatal("restart lost closed terminal prefix")
	}
	health, err = source.Health(time.Now())
	if err != nil || health.UnresolvedCount != 0 {
		t.Fatalf("closed drain did not persist: %+v %v", health, err)
	}
	if source.spool.seg != nil {
		t.Fatal("health retained a closed generation descriptor")
	}
}

func TestPublishedRecoveryDestinationFailureRequiresInventory(t *testing.T) {
	root := t.TempDir()
	input, key, identity := attributionAppend(t, "metrics")
	allocator := recoveryOperationAllocator(t)
	failed := errors.New("synthetic destination configuration failure")
	failDestination := false
	ls, err := OpenLanes(root, identity, deploymentTaxonomy(t), WithGenerationOptions(func(id GenerationIdentity, _ string) ([]Option, error) {
		if failDestination {
			return nil, failed
		}
		return []Option{WithAttribution(id), WithAllocator(allocator)}, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	source := closedRecoverySource(t, ls, key, identity, input)
	failDestination = true
	recoveryID := recoveryUUID(75)
	if _, _, err = ls.BeginRecoveryDestination(source, recoveryID, 0, allocator); !errors.Is(err, failed) {
		t.Fatalf("configuration failure lost: %v", err)
	}
	if _, _, err = ls.BeginRecoveryDestination(source, recoveryID, 0, allocator); !errors.Is(err, ErrLaneSetClosed) {
		t.Fatalf("published uncertain operation retried before inventory: %v", err)
	}
	if allocator.Usage().ActiveRecoveries != 1 || !errors.Is(allocator.Err(), failed) {
		t.Fatal("failed published generation lost its reservation")
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	allocator = recoveryOperationAllocator(t)
	ls = openAttributedLanes(t, root, identity, allocator, nil)
	source = ls.Generations(key)[0]
	failedAttempt, _, err := ls.BeginRecoveryDestination(source, recoveryID, 0, allocator)
	if !errors.Is(err, ErrRecoveryResumeRequired) || !failedAttempt.Closed() {
		t.Fatalf("published failure not retained closed for inventory: %v", err)
	}
}

func TestRetainedInventoryDrainsBeforeAuthenticatedActivation(t *testing.T) {
	root := t.TempDir()
	ls := openLanes(t, root, sessionA)
	first := mustLaneAppend(t, ls, bulkLane, sessionA, 11, "synthetic retained record")
	if _, err := ls.Rotate(bulkLane); err != nil {
		t.Fatal(err)
	}
	second := mustLaneAppend(t, ls, bulkLane, sessionA, 12, "synthetic open record")
	if err := ls.Close(); err != nil {
		t.Fatal(err)
	}
	ls, err := OpenRetainedLanes(root, deploymentTaxonomy(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ls.Close() })
	page := ls.GenerationsPage(bulkLane, 0, 1)
	if len(page) != 1 || !bytes.Equal(page[0].Identity().SpoolID, first.Generation.SpoolID) {
		t.Fatal("retained generation identity changed")
	}
	records, err := page[0].Unresolved()
	if err != nil || len(records) != 1 || string(records[0].Body) != "synthetic retained record" {
		t.Fatalf("startup drain: %v %v", records, err)
	}
	page = ls.GenerationsPage(bulkLane, page[0].Identity().Ordinal, 1)
	if len(page) != 1 || !bytes.Equal(page[0].Identity().SpoolID, second.Generation.SpoolID) {
		t.Fatal("open generation missing from bounded inventory")
	}
	if _, err = ls.Append(bulkLane, sessionA, evid(13), []byte("synthetic refused")); !errors.Is(err, ErrLaneNotReady) {
		t.Fatalf("unauthenticated append: %v", err)
	}
	if _, err = ls.Rotate(bulkLane); !errors.Is(err, ErrLaneNotReady) {
		t.Fatalf("unauthenticated rotation: %v", err)
	}
	if err = ls.ActivateSession(sessionB); err != nil {
		t.Fatal(err)
	}
	if _, err = ls.Append(bulkLane, sessionA, evid(13), []byte("synthetic refused")); !errors.Is(err, ErrAgentUnauthorized) {
		t.Fatalf("old namespace accepted: %v", err)
	}
	if _, err = ls.Append(bulkLane, sessionB, evid(13), []byte("synthetic new namespace")); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("old generation identity replaced: %v", err)
	}
	if _, err = ls.Rotate(bulkLane); err != nil {
		t.Fatal(err)
	}
	next := mustLaneAppend(t, ls, bulkLane, sessionB, 13, "synthetic new namespace")
	if next.Sequence != 1 || bytes.Equal(next.Generation.SpoolID, second.Generation.SpoolID) {
		t.Fatal("activation reused sequence namespace")
	}
	if records, err = page[0].Unresolved(); err != nil || len(records) != 1 || string(records[0].Body) != "synthetic open record" {
		t.Fatalf("rotation lost retained original: %v %v", records, err)
	}
}

func TestRecoveryGenerationReservesBeforePhysicalMetadata(t *testing.T) {
	root := t.TempDir()
	input, key, identity := attributionAppend(t, "metrics")
	measure := func() (uint64, error) {
		var total uint64
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if entry.IsDir() {
				total += 4096
			} else {
				total += uint64(info.Size())
			}
			return nil
		})
		return total, err
	}
	physicalLimit := uint64(1 << 30)
	allocator, err := NewAllocator(AllocatorConfig{Capacity: 128 << 20, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: DefaultRecoveryFootprint(), FreeBytes: func() (uint64, error) {
		used, err := measure()
		if err != nil {
			return 0, err
		}
		if used > physicalLimit {
			return 0, nil
		}
		return physicalLimit - used, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	ls := openAttributedLanes(t, root, identity, allocator, nil)
	source := closedRecoverySource(t, ls, key, identity, input)
	ordinaryBefore := allocator.Usage().OrdinaryUsed
	before, err := measure()
	if err != nil {
		t.Fatal(err)
	}
	physicalLimit = before + allocator.Usage().Floor - 1
	id := recoveryUUID(76)
	if _, _, err = ls.BeginRecoveryDestination(source, id, 0, allocator); !errors.Is(err, ErrReserveUnbacked) {
		t.Fatalf("unbacked creation: %v", err)
	}
	after, err := measure()
	if err != nil || after != before || allocator.Usage().ActiveRecoveries != 0 {
		t.Fatalf("unbacked creation wrote metadata: before=%d after=%d error=%v", before, after, err)
	}
	physicalLimit++
	destination, grant, err := ls.BeginRecoveryDestination(source, id, 0, allocator)
	if err != nil {
		t.Fatalf("metadata consumed recovery backing before acquisition: %v", err)
	}
	controlKey := LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	control, err := ls.CreateRecoveryControlDestination(controlKey, id, 0, grant)
	if err != nil {
		t.Fatal("control required another backed grant", err)
	}
	if allocator.Usage().ActiveRecoveries != 1 || allocator.Usage().OrdinaryUsed != ordinaryBefore {
		t.Fatalf("metadata escaped shared grant: %+v", allocator.Usage())
	}
	for _, g := range []*Generation{destination, control} {
		if _, err := os.Stat(filepath.Join(g.Directory(), recoveryDestinationFile)); err != nil {
			t.Fatal(err)
		}
		if g.NextSequence() != 1 {
			t.Fatal("creation allocated record sequence")
		}
	}
	repeated, sameGrant, err := ls.BeginRecoveryDestination(source, id, 0, allocator)
	if err != nil || repeated != destination || sameGrant != grant {
		t.Fatal("creation retry acquired or published again", err)
	}
}

func TestRecoveryDestinationPreservesSourceBeforeFreezeWithoutCurrentSession(t *testing.T) {
	root := t.TempDir()
	input, key, identity := attributionAppend(t, "metrics")
	allocator := recoveryOperationAllocator(t)
	ls := openAttributedLanes(t, root, identity, allocator, nil)
	source := closedRecoverySource(t, ls, key, identity, input)
	original := source.Identity()
	before, err := os.ReadFile(filepath.Join(source.Directory(), segmentFile))
	if err != nil {
		t.Fatal(err)
	}
	if err := ls.Close(); err != nil {
		t.Fatal(err)
	}
	allocator = recoveryOperationAllocator(t)
	ls, err = OpenRetainedLanes(root, deploymentTaxonomy(t), WithGenerationOptions(func(id GenerationIdentity, _ string) ([]Option, error) {
		return []Option{WithAttribution(id), WithAllocator(allocator)}, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	source = ls.Generations(key)[0]
	recoveryID := recoveryUUID(77)
	destination, _, err := ls.BeginRecoveryDestination(source, recoveryID, 0, allocator)
	if err != nil {
		t.Fatalf("original durable namespace required current session: %v", err)
	}
	if !destination.Identity().Identity.equal(identity) {
		t.Fatal("destination rebound original namespace")
	}
	if held, err := source.RecoverySourceHeld(); err != nil || held {
		t.Fatalf("pre-freeze intent held source: %v %v", held, err)
	}
	if err := ls.Close(); err != nil {
		t.Fatal(err)
	}
	allocator = recoveryOperationAllocator(t)
	changed := identity.clone()
	changed.NetworkScopeID = recoveryUUID(78)
	ls = openAttributedLanes(t, root, changed, allocator, nil)
	source = ls.Generations(key)[0]
	destination, _, err = ls.BeginRecoveryDestination(source, recoveryID, 0, allocator)
	if !errors.Is(err, ErrRecoveryResumeRequired) {
		t.Fatalf("pre-freeze restart lost reserved operation: %v", err)
	}
	got, err := destination.RecoverySourceIdentity()
	if err != nil || !bytes.Equal(encodeIdentity(got), encodeIdentity(original)) {
		t.Fatalf("original source association lost: %+v %v", got, err)
	}
	got.SpoolID[0] ^= 1
	again, err := destination.RecoverySourceIdentity()
	if err != nil || !bytes.Equal(again.SpoolID, original.SpoolID) {
		t.Fatal("caller mutated durable source association", err)
	}
	after, err := os.ReadFile(filepath.Join(source.Directory(), segmentFile))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("pre-freeze restart changed source bytes", err)
	}
	intentPath := filepath.Join(destination.Directory(), recoverySourceFile)
	raw, err := os.ReadFile(intentPath)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-1] ^= 1
	if err := os.WriteFile(intentPath, raw, filePerm); err != nil {
		t.Fatal(err)
	}
	if _, err := destination.RecoverySourceIdentity(); !errors.Is(err, ErrCorruptGeneration) {
		t.Fatalf("damaged intent remained usable: %v", err)
	}
}
