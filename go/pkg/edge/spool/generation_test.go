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
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func TestRecoveryDestinationRemainsSeparateAcrossRestart(t *testing.T) {
	root := t.TempDir()
	ls := openLanes(t, root, sessionA)
	recoveryID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := ls.CreateRecoveryDestination(bulkLane, recoveryID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := ls.OpenGeneration(bulkLane); ok {
		t.Fatal("recovery destination became producer generation")
	}
	first, err := ls.Append(bulkLane, sessionA, evid(41), []byte("synthetic production record"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first.Generation.SpoolID, destination.Identity().SpoolID) {
		t.Fatal("production appended into recovery destination")
	}
	// A second destination after the producer is open must also survive inventory.
	otherID := bytes.Clone(recoveryID)
	other, err := ls.CreateRecoveryDestination(bulkLane, otherID, 1)
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
	ls = openLanes(t, root, sessionA)
	destination, err = ls.CreateRecoveryDestination(bulkLane, recoveryID, 0)
	if err != nil || !bytes.Equal(destination.Identity().SpoolID, original.SpoolID) {
		t.Fatalf("destination not resumed: %v", err)
	}
	resumedAttempt, err := ls.CreateRecoveryDestination(bulkLane, recoveryID, 1)
	if err != nil || resumedAttempt.RecoveryAttempt() != 1 || !bytes.Equal(resumedAttempt.Identity().SpoolID, other.Identity().SpoolID) {
		t.Fatalf("control attempt not resumed: %v", err)
	}
	if len(ls.Generations(bulkLane)) != 3 {
		t.Fatal("resume created another generation")
	}
	if err = destination.SealRecoveryDestination(); err != nil {
		t.Fatal(err)
	}
	if _, err = destination.CommitRelocated(CommittedAttribution{}, nil); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("sealed destination writable: %v", err)
	}
	producer, _ := ls.OpenGeneration(bulkLane)
	if _, err = producer.CommitRelocated(CommittedAttribution{}, nil); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("producer accepted relocation: %v", err)
	}
	second, err := ls.Append(bulkLane, sessionA, evid(42), []byte("synthetic next production record"))
	if err != nil || second.Sequence != 2 || !bytes.Equal(second.Generation.SpoolID, first.Generation.SpoolID) {
		t.Fatalf("destination affected producer: %+v %v", second, err)
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	// The directory role independently detects a missing marker; it cannot
	// silently reopen a recovery destination for ordinary producer writes.
	if err = os.Remove(filepath.Join(other.Directory(), recoveryDestinationFile)); err != nil {
		t.Fatal(err)
	}
	if reopened, err := OpenLanes(root, sessionA, deploymentTaxonomy(t)); !errors.Is(err, ErrCorruptGeneration) {
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
	failed := errors.New("synthetic destination configuration failure")
	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t), WithGenerationOptions(func(GenerationIdentity, string) ([]Option, error) { return nil, failed }))
	if err != nil {
		t.Fatal(err)
	}
	recoveryID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = ls.CreateRecoveryDestination(bulkLane, recoveryID, 0); !errors.Is(err, failed) {
		t.Fatalf("configuration failure lost: %v", err)
	}
	if _, err = ls.CreateRecoveryDestination(bulkLane, recoveryID, 0); !errors.Is(err, ErrLaneSetClosed) {
		t.Fatalf("published uncertain operation retried before inventory: %v", err)
	}
	if err = ls.Close(); err != nil {
		t.Fatal(err)
	}
	ls = openLanes(t, root, sessionA)
	failedAttempt, err := ls.CreateRecoveryDestination(bulkLane, recoveryID, 0)
	if err != nil || !failedAttempt.Closed() {
		t.Fatalf("published failure not retained closed: %v", err)
	}
	nextAttempt, err := ls.CreateRecoveryDestination(bulkLane, recoveryID, 1)
	if err != nil || nextAttempt.Closed() || bytes.Equal(nextAttempt.Identity().SpoolID, failedAttempt.Identity().SpoolID) {
		t.Fatalf("explicit retry not fresh: %v", err)
	}
}
