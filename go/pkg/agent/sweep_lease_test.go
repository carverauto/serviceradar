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
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

//nolint:gochecknoglobals // immutable synthetic fixture, not state
var (
	testLeaseGroup   = uuid.MustParse("11111111-2222-3333-4444-555555555555")
	testLeaseID      = uuid.MustParse("66666666-7777-4888-8999-000000000000")
	testAssignmentID = uuid.MustParse("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
)

func newUUIDBytes() []byte {
	id := uuid.New()

	return id[:]
}

func testLeaseSlot(startSec int64) *edgev1.SweepLeaseSlotV1 {
	return &edgev1.SweepLeaseSlotV1{
		ExecutionId:               newUUIDBytes(),
		SlotStartUnixNano:         startSec * 1_000_000_000,
		CollectionExpiresUnixNano: (startSec + 900) * 1_000_000_000,
	}
}

func testLeasePush(windowStartSec, windowEndSec int64, slots ...*edgev1.SweepLeaseSlotV1) *edgev1.SweepLeaseV1 {
	push := &edgev1.SweepLeaseV1{
		LeaseVersion:         sweepLeaseVersion,
		SweepGroupId:         testLeaseGroup[:],
		LeaseId:              testLeaseID[:],
		ProducerAssignmentId: testAssignmentID[:],
		AuthorityEpoch:       1,
		WindowStartUnixNano:  windowStartSec * 1_000_000_000,
		WindowEndUnixNano:    windowEndSec * 1_000_000_000,
		Slots:                slots,
	}

	if len(slots) > 0 {
		push.ProductionCapability = &edgev1.EdgeSignedCapabilityV1{}
	}

	return push
}

func heldStarts(lease *edgev1.SweepLeaseV1) []int64 {
	starts := make([]int64, 0, len(lease.GetSlots()))
	for _, slot := range lease.GetSlots() {
		starts = append(starts, slot.GetSlotStartUnixNano()/1_000_000_000)
	}

	return starts
}

func equalStarts(got []int64, want ...int64) bool {
	if len(got) != len(want) {
		return false
	}

	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}

	return true
}

func leaseChunks(t *testing.T, push *edgev1.SweepLeaseV1, chunkSize int) []*proto.SweepLeaseChunk {
	t.Helper()

	payload, err := goproto.Marshal(push)
	if err != nil {
		t.Fatalf("marshal lease: %v", err)
	}

	sum := sha256.Sum256(payload)
	digest := hex.EncodeToString(sum[:])
	total := (len(payload) + chunkSize - 1) / chunkSize

	chunks := make([]*proto.SweepLeaseChunk, 0, total)
	for i := 0; i < total; i++ {
		end := min((i+1)*chunkSize, len(payload))
		chunks = append(chunks, &proto.SweepLeaseChunk{
			SweepGroupId:  testLeaseGroup.String(),
			Payload:       payload[i*chunkSize : end],
			ChunkIndex:    int32(i),
			TotalChunks:   int32(total),
			IsFinal:       i == total-1,
			PayloadSha256: digest,
		})
	}

	return chunks
}

func TestSweepLeaseAssemblerReassemblesOnlyOnFinalChunk(t *testing.T) {
	push := testLeasePush(100, 400, testLeaseSlot(100), testLeaseSlot(200), testLeaseSlot(300))
	chunks := leaseChunks(t, push, 16)

	var assembler sweepLeaseAssembler

	for i, chunk := range chunks {
		payload, err := assembler.add(chunk)
		if err != nil {
			t.Fatalf("chunk %d: %v", i, err)
		}

		if i < len(chunks)-1 && payload != nil {
			t.Fatalf("chunk %d: payload before final chunk", i)
		}

		if i == len(chunks)-1 {
			var decoded edgev1.SweepLeaseV1
			if err := goproto.Unmarshal(payload, &decoded); err != nil {
				t.Fatalf("decode reassembled lease: %v", err)
			}

			if !equalStarts(heldStarts(&decoded), 100, 200, 300) {
				t.Fatalf("reassembled slots = %v, want [100 200 300]", heldStarts(&decoded))
			}
		}
	}
}

func TestSweepLeaseAssemblerRejectsTamperedPayload(t *testing.T) {
	chunks := leaseChunks(t, testLeasePush(100, 200, testLeaseSlot(100)), 8)
	chunks[0].Payload[0] ^= 0xff

	var assembler sweepLeaseAssembler

	var err error
	for _, chunk := range chunks {
		if _, err = assembler.add(chunk); err != nil {
			break
		}
	}

	if !errors.Is(err, errInvalidSweepLeaseChunk) {
		t.Fatalf("tampered payload error = %v, want errInvalidSweepLeaseChunk", err)
	}
}

func TestSweepLeaseAssemblerRejectsOutOfOrderChunk(t *testing.T) {
	chunks := leaseChunks(t, testLeasePush(100, 200, testLeaseSlot(100)), 4)
	if len(chunks) < 2 {
		t.Fatalf("need at least two chunks, got %d", len(chunks))
	}

	var assembler sweepLeaseAssembler

	if _, err := assembler.add(chunks[1]); !errors.Is(err, errInvalidSweepLeaseChunk) {
		t.Fatalf("out-of-order error = %v, want errInvalidSweepLeaseChunk", err)
	}
}

func TestSweepLeaseStoreWindowReplacement(t *testing.T) {
	store, err := newSweepLeaseStore(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	group := testLeaseGroup.String()

	held, err := store.Install(testLeasePush(100, 400,
		testLeaseSlot(100), testLeaseSlot(200), testLeaseSlot(300)), group)
	if err != nil {
		t.Fatalf("install full: %v", err)
	}

	if !equalStarts(heldStarts(held), 100, 200, 300) {
		t.Fatalf("after full: %v, want [100 200 300]", heldStarts(held))
	}

	// A tail window replaces its range: the installed 300 is swapped for the
	// pushed one and 400 extends the lease.
	replacement300 := testLeaseSlot(300)

	held, err = store.Install(testLeasePush(300, 500, replacement300, testLeaseSlot(400)), group)
	if err != nil {
		t.Fatalf("install tail: %v", err)
	}

	if !equalStarts(heldStarts(held), 100, 200, 300, 400) {
		t.Fatalf("after tail: %v, want [100 200 300 400]", heldStarts(held))
	}

	if got := held.GetSlots()[2].GetExecutionId(); string(got) != string(replacement300.GetExecutionId()) {
		t.Fatal("tail did not replace the slot inside its window")
	}

	// A shrink window carrying only 100 drops 200 without a delete message.
	held, err = store.Install(testLeasePush(100, 250, testLeaseSlot(100)), group)
	if err != nil {
		t.Fatalf("install shrink: %v", err)
	}

	if !equalStarts(heldStarts(held), 100, 300, 400) {
		t.Fatalf("after shrink: %v, want [100 300 400]", heldStarts(held))
	}

	ack := sweepLeaseAckInstalled(group, held, "deadbeef")
	if !ack.GetInstalled() || ack.GetInstalledSlotCount() != 3 {
		t.Fatalf("ack = %+v, want installed with 3 slots", ack)
	}

	if want := int64(1300) * 1_000_000_000; ack.GetInstalledThroughUnixNano() != want {
		t.Fatalf("installed_through = %d, want %d", ack.GetInstalledThroughUnixNano(), want)
	}
}

func TestSweepLeaseStoreNewLeaseReplacesAndPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	group := testLeaseGroup.String()

	store, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	if _, err := store.Install(testLeasePush(100, 300, testLeaseSlot(100), testLeaseSlot(200)), group); err != nil {
		t.Fatalf("install: %v", err)
	}

	reopened, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}

	if held := reopened.Get(group); held == nil || !equalStarts(heldStarts(held), 100, 200) {
		t.Fatalf("after restart: %v, want lease with [100 200]", held)
	}

	// A different lease id discards the installed lease outright.
	next := testLeasePush(500, 600, testLeaseSlot(500))
	next.LeaseId = newUUIDBytes()

	held, err := reopened.Install(next, group)
	if err != nil {
		t.Fatalf("install new lease: %v", err)
	}

	if !equalStarts(heldStarts(held), 500) {
		t.Fatalf("after new lease: %v, want [500]", heldStarts(held))
	}

	revoked := testLeasePush(600, 601)
	revoked.LeaseId = next.LeaseId
	revoked.Revoked = true

	held, err = reopened.Install(revoked, group)
	if err != nil {
		t.Fatalf("install revocation: %v", err)
	}

	if held != nil {
		t.Fatalf("after revocation: %v, want nil", held)
	}

	again, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("reopen after revocation: %v", err)
	}

	if held := again.Get(group); held != nil {
		t.Fatalf("revoked lease survived restart: %v", heldStarts(held))
	}

	files, err := filepath.Glob(filepath.Join(dir, "*.pb"))
	if err != nil {
		t.Fatalf("glob lease files: %v", err)
	}

	if len(files) != 0 {
		t.Fatalf("revoked lease files remain: %v", files)
	}
}

func TestSweepLeaseInstallRefusals(t *testing.T) {
	group := testLeaseGroup.String()

	cases := []struct {
		name   string
		mutate func(*edgev1.SweepLeaseV1)
	}{
		{"wrong version", func(p *edgev1.SweepLeaseV1) { p.LeaseVersion = 2 }},
		{"wrong group", func(p *edgev1.SweepLeaseV1) { p.SweepGroupId = newUUIDBytes() }},
		{"empty window", func(p *edgev1.SweepLeaseV1) { p.WindowEndUnixNano = p.WindowStartUnixNano }},
		{"slots without capability", func(p *edgev1.SweepLeaseV1) { p.ProductionCapability = nil }},
		{"slot outside window", func(p *edgev1.SweepLeaseV1) { p.Slots[0].SlotStartUnixNano = 50 * 1_000_000_000 }},
		{"slots not ascending", func(p *edgev1.SweepLeaseV1) { p.Slots[1].SlotStartUnixNano = p.Slots[0].SlotStartUnixNano }},
		{"empty collection window", func(p *edgev1.SweepLeaseV1) {
			p.Slots[0].CollectionExpiresUnixNano = p.Slots[0].SlotStartUnixNano
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, err := newSweepLeaseStore(t.TempDir())
			if err != nil {
				t.Fatalf("open store: %v", err)
			}

			push := testLeasePush(100, 400, testLeaseSlot(100), testLeaseSlot(200), testLeaseSlot(300))
			tc.mutate(push)

			if _, err := store.Install(push, group); !errors.Is(err, errInvalidSweepLease) {
				t.Fatalf("Install error = %v, want errInvalidSweepLease", err)
			}

			if held := store.Get(group); held != nil {
				t.Fatalf("refused push left a lease installed: %v", heldStarts(held))
			}
		})
	}
}

func sweepLeaseAcks(stream *fakeControlStreamClient) []*proto.SweepLeaseAck {
	stream.mu.Lock()
	defer stream.mu.Unlock()

	acks := make([]*proto.SweepLeaseAck, 0, len(stream.sent))
	for _, req := range stream.sent {
		if ack := req.GetSweepLeaseAck(); ack != nil {
			acks = append(acks, ack)
		}
	}

	return acks
}

// TestSweepLeaseAgentInstallPersistsAndAcks drives a chunked push through the
// agent's control-stream handler: the install ack is what core records, and a
// new push loop on the same state dir is the agent after a restart.
func TestSweepLeaseAgentInstallPersistsAndAcks(t *testing.T) {
	runtimeRoot := t.TempDir()
	t.Setenv("SERVICERADAR_AGENT_RUNTIME_ROOT", runtimeRoot)
	dir := filepath.Join(runtimeRoot, "sweep-leases")
	// Check before opening the store so a broken resolver never writes outside
	// this test's runtime volume. The assertions below exercise both durable files.
	if got := defaultSweepLeaseDir(); got != dir {
		t.Fatalf("lease directory = %q, want runtime-volume path %q", got, dir)
	}
	start := time.Now().Unix()
	group := testLeaseGroup.String()
	push := testLeasePush(start, start+300, testLeaseSlot(start), testLeaseSlot(start+100), testLeaseSlot(start+200))
	chunks := leaseChunks(t, push, 32)

	loop := &PushLoop{logger: logger.NewTestLogger()}
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)

	var assembler sweepLeaseAssembler
	for _, chunk := range chunks {
		loop.handleSweepLeaseChunk(chunk, &assembler, sender)
	}

	acks := sweepLeaseAcks(stream)
	if len(acks) != 1 {
		t.Fatalf("acks = %d, want 1 completed ack", len(acks))
	}

	ack := acks[0]
	if !ack.GetInstalled() || ack.GetError() != "" {
		t.Fatalf("ack = %+v, want a successful install", ack)
	}

	if ack.GetSweepGroupId() != group || ack.GetPayloadSha256() != chunks[0].GetPayloadSha256() {
		t.Fatalf("ack identity = %s %s, want %s %s", ack.GetSweepGroupId(), ack.GetPayloadSha256(), group, chunks[0].GetPayloadSha256())
	}

	if ack.GetInstalledSlotCount() != 3 {
		t.Fatalf("installed slot count = %d, want 3", ack.GetInstalledSlotCount())
	}

	if want := (start + 1100) * 1_000_000_000; ack.GetInstalledThroughUnixNano() != want {
		t.Fatalf("installed_through = %d, want %d", ack.GetInstalledThroughUnixNano(), want)
	}

	store, err := loop.sweepLeaseStore()
	if err != nil {
		t.Fatalf("open installed lease store: %v", err)
	}
	executionID, err := uuid.FromBytes(push.Slots[0].ExecutionId)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.MarkExecuted(group, executionID.String(), push.Slots[0].CollectionExpiresUnixNano, time.Now()); err != nil {
		t.Fatalf("persist executed slot: %v", err)
	}
	for _, name := range []string{group + ".pb", group + ".executed.json"} {
		if info, err := os.Stat(filepath.Join(dir, name)); err != nil || info.Size() == 0 {
			t.Fatalf("missing durable runtime file %s: %v", name, err)
		}
	}
	restarted := &PushLoop{logger: logger.NewTestLogger()}

	store, err = restarted.sweepLeaseStore()
	if err != nil {
		t.Fatalf("reopen lease store: %v", err)
	}

	held := store.Get(group)
	if held == nil || !equalStarts(heldStarts(held), start, start+100, start+200) {
		t.Fatalf("lease after restart = %v, want installed three-slot window", held)
	}
	if !store.Executed(group, executionID.String()) {
		t.Fatal("executed slot marker lost after runtime-volume reopen")
	}
}

func TestSweepLeaseExecutionPersistenceFailureDoesNotSettleSlot(t *testing.T) {
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	group := testLeaseGroup.String()
	dir := t.TempDir()
	store, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Install(built.lease, group); err != nil {
		t.Fatal(err)
	}
	path := store.executedPath(group)
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	expires := built.lease.Slots[0].CollectionExpiresUnixNano
	if err := store.MarkExecuted(group, built.executionID, expires, testSlotStart); err == nil {
		t.Fatal("publishing executions over a directory succeeded")
	}
	if store.Executed(group, built.executionID) {
		t.Fatal("failed persistence settled the execution")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkExecuted(group, built.executionID, expires, testSlotStart); err != nil {
		t.Fatal(err)
	}
	reopened, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !reopened.Executed(group, built.executionID) {
		t.Fatal("successfully persisted execution disappeared on reopen")
	}
}
