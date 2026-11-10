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

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	"github.com/carverauto/serviceradar/go/pkg/edge/admission"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/proto"
)

// runEdgeRecordSender must return promptly (not block on a ticker or dial)
// whenever it is unconfigured or missing required fields, since it runs as a
// best-effort background goroutine alongside the push loop.
func mustReturnPromptly(t *testing.T, fn func()) {
	t.Helper()

	done := make(chan struct{})
	go func() {
		fn()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("did not return promptly")
	}
}

func TestRunEdgeRecordSenderNoopWhenNil(t *testing.T) {
	t.Parallel()
	cfg := &agent.ServerConfig{}
	mustReturnPromptly(t, func() {
		runEdgeRecordSender(context.Background(), cfg, nil, logger.NewTestLogger())
	})
}

type senderGuardLogger struct {
	logger.Logger
	output zerolog.Logger
}

func (l *senderGuardLogger) Error() *zerolog.Event { return l.output.Error() }

func TestRunEdgeRecordSenderConfigurationGuards(t *testing.T) {
	sp, _, _, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: t.TempDir()}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	// A sender with no gateway address anywhere stops and says why.
	dir := filepath.Join(t.TempDir(), "spool")
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{
		SpoolDir: dir, Security: &models.SecurityConfig{Mode: models.SecurityModeNone},
	}}
	var output bytes.Buffer
	log := &senderGuardLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	mustReturnPromptly(t, func() { runEdgeRecordSender(ctx, cfg, sp, log) })
	var event struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(output.Bytes(), &event); err != nil {
		t.Fatal(err)
	}
	if want := "Edge record sender has no gateway address"; event.Message != want {
		t.Fatalf("message = %q, want %q", event.Message, want)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("guard created spool: %v", err)
	}
}

// A spool that cannot be opened is reported, not fatal: the caller records it
// as spool_unavailable and runs on without one.
func TestOpenEdgeRecordSpoolReportsADirectoryItCannotCreate(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: filepath.Join(blocker, "spool")}}
	if sp, _, _, err := openEdgeRecordSpool(cfg); err == nil || sp != nil {
		t.Fatalf("openEdgeRecordSpool under a file = (%v, %v), want an error and no spool", sp, err)
	}
}

// Core's budget applies at admission in both directions. A budget below what
// the spool holds refuses new appends without dropping anything, and raising it
// admits again.
func TestEdgeSpoolBudgetFromConfigAppliesAtAdmission(t *testing.T) {
	sp, gate, budget := openTestEdgeSpool(t, 2<<20)
	defer func() { _ = sp.Close() }()

	if _, err := sp.Append(make([]byte, 16), make([]byte, 1<<20)); err != nil {
		t.Fatal(err)
	}
	if _, err := sp.Append(append(make([]byte, 15), 1), make([]byte, 1<<20)); !errors.Is(err, spool.ErrAdmissionRefused) {
		t.Fatalf("append past the ordinary byte budget = %v, want byte-budget refusal", err)
	}
	records, err := sp.Unresolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("refused append changed spool: %d records", len(records))
	}
	if err := budget.Apply(defaultEdgeSpoolMaxBytes); err != nil {
		t.Fatal(err)
	}
	if _, err := sp.Append(append(make([]byte, 15), 1), make([]byte, 1<<20)); err != nil {
		t.Fatalf("append after the budget was raised = %v, want admitted", err)
	}
	// A configured budget below recovery's floor must stop new producer work,
	// rather than keep admitting against the previous larger capacity.
	if err := budget.Apply(16 << 20); !errors.Is(err, spool.ErrInvalidAllocatorConfig) {
		t.Fatalf("undersized budget = %v, want configuration refusal", err)
	}
	if _, err := sp.Append(append(make([]byte, 15), 2), []byte("synthetic pending record")); !errors.Is(err, spool.ErrAdmissionPaused) {
		t.Fatalf("append after refused budget = %v, want admission paused", err)
	}
	if !gate.BulkPaused() {
		t.Fatal("refused configured budget was not visible as paused")
	}
	if got, err := sp.Unresolved(); err != nil || len(got) != 2 {
		t.Fatalf("refused budget changed retained records: %d, %v", len(got), err)
	}
	if err := budget.Apply(defaultEdgeSpoolMaxBytes); err != nil {
		t.Fatal(err)
	}
	if _, err := sp.Append(append(make([]byte, 15), 2), []byte("synthetic pending record")); err != nil {
		t.Fatalf("append after valid budget restored = %v", err)
	}
}

// openTestEdgeSpool opens the agent spool in a temporary directory and applies
// a config-delivered budget of maxBytes.
func openTestEdgeSpool(t *testing.T, maxBytes uint64) (*spool.Spool, *admission.Gate, *edgeSpoolBudget) {
	t.Helper()
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: t.TempDir()}}
	sp, gate, budget, err := openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reserve, err := spool.DefaultRecoveryFootprint().PerRecovery()
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.Apply(reserve + (1 << 20) + maxBytes); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sp.Close() })
	raw, err := spool.Open(t.TempDir(), spool.WithAllocator(budget.allocator), spool.WithAdmissionGate(func(flow string, cost uint64) bool { return gate.AdmitFlow(flow, cost, time.Now()) == admission.Admit }))
	if err != nil {
		t.Fatal(err)
	}
	return raw, gate, budget
}

// Recovery admission must inspect the spool's actual filesystem on each call.
// A missing directory is a deterministic probe failure without filling a disk.
func TestEdgeSpoolRecoveryFailsClosedWhenFilesystemCannotBeProbed(t *testing.T) {
	dir := t.TempDir()
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir}}
	sp, _, budget, err := openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := sp.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := budget.allocator.AcquireRecovery(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("recovery on missing filesystem path = %v, want probe failure", err)
	}
}

// Producer admission pauses at the spool's high water, before the allocator's
// hard ceiling refuses anything. A record refused while paused is not written,
// however often it is retried, so its producer keeps it and retries it unchanged.
// Once the sender's acknowledgement lets the spool reclaim, which brings its
// bytes to the low water, the same record is admitted.
func TestEdgeSpoolAdmissionPausesAtHighWaterAndResumesAfterReclaim(t *testing.T) {
	sp, gate, _ := openTestEdgeSpool(t, 4<<20)
	defer func() { _ = sp.Close() }()
	var err error
	eventID := func(i int) []byte {
		id := make([]byte, 16)
		binary.BigEndian.PutUint64(id[8:], uint64(i))
		return id
	}
	body := make([]byte, 64<<10)

	var admitted [][]byte
	var refused error
	for i := 1; refused == nil; i++ {
		if i > 100 {
			t.Fatal("the spool admitted 100 records without pausing")
		}
		if _, refused = sp.Append(eventID(i), body); refused == nil {
			admitted = append(admitted, eventID(i))
		}
	}
	if !errors.Is(refused, spool.ErrAdmissionPaused) {
		t.Fatalf("first refusal after %d records = %v, want the high-water pause before the hard ceiling", len(admitted), refused)
	}
	if !gate.BulkPaused() {
		t.Fatal("the gate does not report the pause")
	}

	held := eventID(len(admitted) + 1)
	for range 3 {
		if _, err = sp.Append(held, body); !errors.Is(err, spool.ErrAdmissionPaused) {
			t.Fatalf("retry while paused = %v, want ErrAdmissionPaused", err)
		}
	}
	records, err := sp.Unresolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != len(admitted) {
		t.Fatalf("refused retries changed the spool: %d records, want %d", len(records), len(admitted))
	}

	through := uint64(len(admitted))
	ack := &edgev1.EdgeDeliveryAckV1{ResolvedThroughSequence: through}
	for i, id := range admitted {
		ack.Dispositions = append(ack.Dispositions, &edgev1.EdgeRecordDisposition{
			Sequence: uint64(i + 1), EventId: id, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
		})
	}
	evidence, err := proto.Marshal(ack)
	if err != nil {
		t.Fatal(err)
	}
	if err = sp.ResolveWithEvidence(through, evidence); err != nil {
		t.Fatal(err)
	}
	if gate.BulkPaused() {
		t.Fatal("admission stayed paused after reclaim emptied the spool")
	}
	if _, err = sp.Append(held, body); err != nil {
		t.Fatalf("the held record after reclaim = %v, want admitted", err)
	}
}

// Between the watermarks the agent spool shares its room across producer
// flows. A burst that has used its share is deferred before the high-water
// pause, while a steady flow that has used less keeps entering; the burst's
// deferred record is admitted once the steady flow has caught up.
func TestEdgeSpoolBurstDefersToASteadyFlowBetweenWatermarks(t *testing.T) {
	sp, gate, _ := openTestEdgeSpool(t, 8<<20)
	defer func() { _ = sp.Close() }()
	var err error
	issued := 0
	eventID := func() []byte {
		issued++
		id := make([]byte, 16)
		binary.BigEndian.PutUint64(id[8:], uint64(issued))
		return id
	}
	body := make([]byte, 64<<10)
	if _, err = sp.AppendFlow("steady", eventID(), body); err != nil {
		t.Fatalf("first steady record = %v", err)
	}

	burstHead := eventID()
	for burst := 0; ; burst++ {
		if burst > 1000 {
			t.Fatal("the burst was never deferred")
		}
		if _, err = sp.AppendFlow("burst", burstHead, body); err != nil {
			break
		}
		burstHead = eventID()
	}
	if !errors.Is(err, spool.ErrAdmissionPaused) {
		t.Fatalf("burst refusal = %v, want a retryable admission refusal", err)
	}
	if gate.BulkPaused() {
		t.Fatal("the burst reached the high-water pause; it should defer at its share")
	}

	steady := 0
	for {
		if _, err = sp.AppendFlow("steady", eventID(), body); err != nil {
			t.Fatalf("steady record while the burst waits = %v, want admitted", err)
		}
		steady++
		if _, err = sp.AppendFlow("burst", burstHead, body); err == nil {
			break
		}
		if steady > 1000 {
			t.Fatal("the burst's deferred record was never admitted")
		}
	}
	if steady < 2 {
		t.Fatalf("the burst was readmitted after %d steady record, want it to wait for the steady flow to catch up", steady)
	}
}

func TestSenderPreservesGenerationNamespacesAndContinuesPastACoverageGap(t *testing.T) {
	dir := t.TempDir()
	lanes, identity, key := testTransportLanes(t, dir)
	firstRecord := spooledEdgeRecord(t, time.Now().Add(-time.Hour))
	firstReceipt, err := lanes.Append(key, identity, firstRecord.eventID, firstRecord.body)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lanes.Rotate(key); err != nil {
		t.Fatal(err)
	}
	gapRecord := spooledEdgeRecord(t, time.Now().Add(-time.Hour))
	first, err := lanes.Append(key, identity, gapRecord.eventID, gapRecord.body)
	if err != nil {
		t.Fatal(err)
	}
	closed := lanes.Generations(key)[1]
	if _, err := lanes.Rotate(key); err != nil {
		t.Fatal(err)
	}
	lastRecord := spooledEdgeRecord(t, time.Now().Add(-time.Hour))
	last, err := lanes.Append(key, identity, lastRecord.eventID, lastRecord.body)
	if err != nil {
		t.Fatal(err)
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(filepath.Join(closed.Directory(), "lane.seg"), 0); err != nil {
		t.Fatal(err)
	}
	store, _, budget, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	health := edgeSpoolStatusSampler(store, budget)()
	if !health.HealthAvailable || health.UnresolvedCount != 3 || health.GapCount != 1 || len(health.GapSequences) != 0 || len(health.GenerationGaps) != 1 {
		t.Fatalf("aggregate health = %v", health)
	}
	gap := health.GenerationGaps[0]
	if !bytes.Equal(gap.SpoolGenerationId, first.Generation.SpoolID) || gap.Sequence != 1 || gap.RouteProfile != key.RouteProfile || gap.TrafficClass != key.TrafficClass {
		t.Fatalf("qualified gap = %v", gap)
	}
	gateway, address := listenGrantGateway(t, false)
	runners, closeSender, err := newEdgeRecordSenders(context.Background(), address, &models.SecurityConfig{Mode: models.SecurityModeNone}, store, logger.NewTestLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer closeSender()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var runner *edgeLaneSender
	for _, candidate := range runners {
		if candidate.lane == key {
			runner = candidate
		}
	}
	if runner == nil {
		t.Fatal("missing bulk lane worker")
	}
	for i := 0; i < 2; i++ {
		if _, err := runner.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	requests, frames := gateway.snapshot()
	if len(frames) != 2 || len(requests) != 2 {
		t.Fatalf("requests=%d frames=%d", len(requests), len(frames))
	}
	if !bytes.Equal(requests[0].spoolID, firstReceipt.Generation.SpoolID) || !bytes.Equal(requests[1].spoolID, last.Generation.SpoolID) {
		t.Fatal("delivery rebound a generation identity")
	}
	if !bytes.Equal(frames[0].RecordBytes, firstRecord.body) || !bytes.Equal(frames[1].RecordBytes, lastRecord.body) {
		t.Fatal("delivery rewrote retained bytes")
	}
}

func TestRecoveryLaneDeliveryProgressesWhileBulkSessionStalls(t *testing.T) {
	dir := t.TempDir()
	lanes, identity, bulk := testTransportLanes(t, dir)
	recovery := spool.LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	bulkRecord := spooledEdgeRecord(t, time.Now().Add(time.Hour))
	controlRecord := spooledEdgeRecord(t, time.Now().Add(time.Hour))
	for _, item := range []struct {
		lane   spool.LaneKey
		record spooledRecord
	}{{bulk, bulkRecord}, {recovery, controlRecord}} {
		if _, err := lanes.Append(item.lane, identity, item.record.eventID, item.record.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	gateway, address := listenGrantGateway(t, false)
	gateway.mu.Lock()
	gateway.blockedBulk = make(chan struct{})
	blocked := gateway.blockedBulk
	gateway.mu.Unlock()
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir, GatewayAddr: address, Security: &models.SecurityConfig{Mode: models.SecurityModeNone}, PollInterval: agent.Duration(10 * time.Millisecond)}}
	store, _, _, err := openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	done := make(chan struct{})
	go func() { defer close(done); runEdgeRecordSender(ctx, cfg, store, logger.NewTestLogger()) }()
	defer func() { cancel(); <-done }()
	select {
	case <-blocked:
	case <-ctx.Done():
		t.Fatal("bulk session never opened")
	}
	control := store.Lanes().Generations(recovery)[0]
	for control.Resolved() != 1 {
		select {
		case <-ctx.Done():
			t.Fatal("stalled bulk prevented recovery lane resolution")
		case <-time.After(10 * time.Millisecond):
		}
	}
	_, frames := gateway.snapshot()
	if len(frames) != 1 || !bytes.Equal(frames[0].RecordBytes, controlRecord.body) {
		t.Fatalf("delivered frames = %v, want only exact recovery bytes", frames)
	}
	if store.Lanes().Generations(bulk)[0].Resolved() != 0 {
		t.Fatal("stalled bulk unexpectedly resolved")
	}
}

func TestUnsupportedLegacyStorageIsRetainedAccountedAndNeverDelivered(t *testing.T) {
	dir := t.TempDir()
	old := []byte("synthetic unsupported legacy bytes")
	path := filepath.Join(dir, "lane.seg")
	if err := os.WriteFile(path, old, 0o600); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, bytes.Repeat([]byte("x"), 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "legacy-link")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	store, _, budget, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	linkInfo, err := os.Lstat(link)
	if err != nil {
		t.Fatal(err)
	}
	want := uint64(len(old)) + uint64(linkInfo.Size())
	status := edgeSpoolStatusSampler(store, budget)()
	if !status.HealthAvailable || status.RetainedLegacyBytes != want || status.BytesUsed != want || status.UnresolvedCount != 0 {
		t.Fatalf("retained status = %v", status)
	}
	gateway, address := listenGrantGateway(t, false)
	runners, closeSender, err := newEdgeRecordSenders(context.Background(), address, &models.SecurityConfig{Mode: models.SecurityModeNone}, store, logger.NewTestLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer closeSender()
	for _, runner := range runners {
		if _, err := runner.RunOnce(context.Background()); !errors.Is(err, sender.ErrNoUnresolvedRecords) {
			t.Fatalf("legacy delivery: %v", err)
		}
	}
	requests, frames := gateway.snapshot()
	if len(requests) != 0 || len(frames) != 0 {
		t.Fatal("legacy bytes entered delivery")
	}
	if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, old) {
		t.Fatalf("legacy bytes changed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "spool_id")); !os.IsNotExist(err) {
		t.Fatalf("created legacy identity: %v", err)
	}
}

// lineLogger is the agent logger interface pointed at a buffer, so a test can
// read the lines runEdgeRecordSenderOnce actually emitted.
type lineLogger struct{ z zerolog.Logger }

func newLineLogger(w io.Writer) *lineLogger {
	return &lineLogger{z: zerolog.New(w)}
}

func (l *lineLogger) Trace() *zerolog.Event { return l.z.Trace() }
func (l *lineLogger) Debug() *zerolog.Event { return l.z.Debug() }
func (l *lineLogger) Info() *zerolog.Event  { return l.z.Info() }
func (l *lineLogger) Warn() *zerolog.Event  { return l.z.Warn() }
func (l *lineLogger) Error() *zerolog.Event { return l.z.Error() }
func (l *lineLogger) Fatal() *zerolog.Event { return l.z.Fatal() }
func (l *lineLogger) Panic() *zerolog.Event { return l.z.Panic() }
func (l *lineLogger) With() zerolog.Context { return l.z.With() }
func (l *lineLogger) WithComponent(component string) zerolog.Logger {
	return l.z.With().Str("component", component).Logger()
}
func (l *lineLogger) WithFields(fields map[string]interface{}) zerolog.Logger {
	return l.z.With().Fields(fields).Logger()
}
func (l *lineLogger) SetLevel(level zerolog.Level) { l.z = l.z.Level(level) }
func (*lineLogger) SetDebug(bool)                  {}

// permanentPrefixThenFail acks the first two frames as REJECTED_PERMANENT and
// then fails the stream, so the sender has persisted a prefix and still returns
// an error. The third frame stays unresolved.
type permanentPrefixThenFail struct {
	edgev1.UnimplementedEdgeRecordIngestServiceServer
}

func (permanentPrefixThenFail) Stream(stream grpc.BidiStreamingServer[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage]) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	open := first.GetLaneOpen()
	if open == nil {
		return status.Error(codes.InvalidArgument, "expected lane_open")
	}
	if err := stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: &edgev1.EdgeRecordLaneOpenAck{
			SpoolId:             open.GetSpoolId(),
			SessionNonce:        open.GetSessionNonce(),
			GrantedByteCredits:  open.GetRequestedByteCredits(),
			GrantedFrameCredits: open.GetRequestedFrameCredits(),
			RouteProfile:        open.GetRouteProfile(),
			TrafficClass:        open.GetTrafficClass(),
		}},
	}); err != nil {
		return err
	}
	var frames []*edgev1.EdgeDeliveryFrameV1
	for {
		msg, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		frame := msg.GetDeliveryFrame()
		if frame == nil {
			return status.Error(codes.InvalidArgument, "expected delivery_frame")
		}
		frames = append(frames, frame)
	}
	if len(frames) != 3 {
		return status.Error(codes.FailedPrecondition, "expected three frames")
	}
	ack := &edgev1.EdgeDeliveryAckV1{
		SpoolId:                 open.GetSpoolId(),
		SessionNonce:            open.GetSessionNonce(),
		ResolvedThroughSequence: frames[1].GetSequence(),
	}
	for _, frame := range frames[:2] {
		ack.Dispositions = append(ack.Dispositions, &edgev1.EdgeRecordDisposition{
			Sequence:      frame.GetSequence(),
			EventId:       frame.GetRecordBytes(),
			Kind:          edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT,
			RejectionCode: "FENCE_STALE",
		})
	}
	if err := stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: ack},
	}); err != nil {
		return err
	}
	return status.Error(codes.Unavailable, "synthetic failure after the permanent prefix")
}

func dialPermanentPrefix(t *testing.T) edgev1.EdgeRecordIngestServiceClient {
	t.Helper()
	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	edgev1.RegisterEdgeRecordIngestServiceServer(server, permanentPrefixThenFail{})
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return listener.Dial()
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return edgev1.NewEdgeRecordIngestServiceClient(conn)
}

// A run that has already persisted a permanent prefix, then fails, is the only
// pass that sees those rejection codes. The log has to name the code once.
func TestFailedSenderRunLogsThePermanentPrefix(t *testing.T) {
	sp, err := spool.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sp.Close() })
	for range 3 {
		id, err := edgerecord.NewUUIDv7()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := sp.Append(id, id); err != nil {
			t.Fatal(err)
		}
	}
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	s, err := sender.New(sp, dialPermanentPrefix(t), sender.Config{
		SpoolID:                 spoolID,
		RouteProfile:            edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:            edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		RequestedByteCredits:    1 << 20,
		RequestedFrameCredits:   10,
		PersistAcknowledgements: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	runEdgeRecordSenderOnce(context.Background(), s, newLineLogger(&buf))
	logText := buf.String()
	t.Logf("sender log:\n%s", logText)
	const permanent = "Edge record gateway rejected records permanently; they move to local spool quarantine"
	if got := strings.Count(logText, permanent); got != 1 {
		t.Fatalf("permanent rejection lines = %d, want 1\n%s", got, logText)
	}
	if !strings.Contains(logText, `"rejection_code":"FENCE_STALE"`) || !strings.Contains(logText, `"records":2`) {
		t.Fatalf("log did not name FENCE_STALE once for both persisted records\n%s", logText)
	}
	if !strings.Contains(logText, "Edge record sender run failed") {
		t.Fatalf("failed run was not logged\n%s", logText)
	}
}

func TestSenderStartupReportsAmbiguousSlot(t *testing.T) {
	dir := t.TempDir()
	lanes, identity, key := testTransportLanes(t, dir)
	if _, err := lanes.Append(key, identity, make([]byte, 16), []byte("synthetic")); err != nil {
		t.Fatal(err)
	}
	generation := lanes.Generations(key)[0]
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(filepath.Join(generation.Directory(), "lane.seg"), 0); err != nil {
		t.Fatal(err)
	}
	store, _, budget, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	var output bytes.Buffer
	log := &senderGuardLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)}
	runEdgeRecordSender(context.Background(), &agent.ServerConfig{}, store, log)
	var found bool
	dec := json.NewDecoder(&output)
	for dec.More() {
		var event map[string]any
		if err := dec.Decode(&event); err != nil {
			t.Fatal(err)
		}
		if event["sequence"] == float64(1) && event["outcome"] == "AMBIGUOUS_ALLOCATED_SLOT" {
			found = true
		}
	}
	if !found {
		t.Fatal("startup did not report the ambiguous allocated slot")
	}
	// The same reopened spool reports the wedge through the runtime status path.
	status := edgeSpoolStatusSampler(store, budget)()
	if !status.GetWedged() || status.GetGapCount() != 1 || status.GetUnresolvedCount() != 1 ||
		len(status.GetGenerationGaps()) != 1 || status.GetGenerationGaps()[0].Sequence != 1 || status.GetOldestUnresolvedAgeKnown() {
		t.Fatalf("reopened spool status = %v", status)
	}
}

func TestSpoolRestartLogsBoundedSampleAndRemainder(t *testing.T) {
	resolution := spool.Resolution{}
	for seq := uint64(1); seq <= 35; seq++ {
		resolution.Slots = append(resolution.Slots, spool.SlotResolution{Sequence: seq, Outcome: spool.OutcomeAmbiguousAllocated})
	}
	var output bytes.Buffer
	log := &senderGuardLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)}
	logEdgeSpoolRestart(resolution, spool.GenerationIdentity{}, log)
	dec := json.NewDecoder(&output)
	slots, total, extra := 0, 0, 0
	for dec.More() {
		var event map[string]any
		if err := dec.Decode(&event); err != nil {
			t.Fatal(err)
		}
		if _, ok := event["sequence"]; ok {
			slots++
		}
		if v, ok := event["coverage_slots"].(float64); ok {
			total = int(v)
		}
		if v, ok := event["additional_slots"].(float64); ok {
			extra = int(v)
		}
	}
	if slots != 32 || total != 35 || extra != 3 {
		t.Fatalf("slots=%d total=%d extra=%d", slots, total, extra)
	}
}

func TestSpoolStatusSamplesLiveUsageAndBudget(t *testing.T) {
	dir := t.TempDir()
	commitSpool(t, dir, []spooledRecord{{eventID: make([]byte, 16), body: []byte("synthetic")}})
	store, _, budget, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	sample := edgeSpoolStatusSampler(store, budget)
	before := sample()
	if err := budget.Apply(defaultEdgeSpoolMaxBytes / 2); err != nil {
		t.Fatal(err)
	}
	after := sample()
	if !after.HealthAvailable || after.UnresolvedCount != 1 || after.UnresolvedBytes != uint64(len("synthetic")) || after.BytesUsed != before.BytesUsed || after.BudgetBytes != defaultEdgeSpoolMaxBytes/2 {
		t.Fatalf("before=%v after=%v", before, after)
	}
}

func TestRecoverySuspendsAndJoinsAnInflightSourceSession(t *testing.T) {
	dir := t.TempDir()
	lanes, identity, key := testTransportLanes(t, dir)
	record := spooledEdgeRecord(t, time.Now().Add(time.Hour))
	if _, err := lanes.Append(key, identity, record.eventID, record.body); err != nil {
		t.Fatal(err)
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	gateway, address := listenGrantGateway(t, false)
	gateway.mu.Lock()
	gateway.blockedBulk = make(chan struct{})
	opened := gateway.blockedBulk
	gateway.mu.Unlock()
	store, _, _, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{SpoolDir: dir}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	workers, closeWorkers, err := newEdgeRecordSenders(ctx, address, &models.SecurityConfig{Mode: models.SecurityModeNone}, store, logger.NewTestLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer closeWorkers()
	var worker *edgeLaneSender
	for _, candidate := range workers {
		if candidate.lane == key {
			worker = candidate
		}
	}
	if worker == nil {
		t.Fatal("bulk worker absent")
	}
	done := make(chan struct{})
	go func() { defer close(done); _, _ = worker.RunOnce(ctx) }()
	select {
	case <-opened:
	case <-ctx.Done():
		t.Fatal("source stream never became in flight")
	}
	generation := store.Lanes().Generations(key)[0]
	stopCtx, stopCancel := context.WithTimeout(ctx, time.Second)
	defer stopCancel()
	resume, err := worker.sessions.suspend(stopCtx, generation)
	if err != nil {
		t.Fatal("source did not cancel and join", err)
	}
	defer resume()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("canceled source worker did not finish")
	}
	if _, err = worker.runSource(ctx, agent.RecordSpoolSource{Identity: generation.Identity(), Source: generation}); !errors.Is(err, agent.ErrRecoveryPending) {
		t.Fatal("new source session entered while frozen", err)
	}
	if generation.Resolved() != 0 {
		t.Fatal("canceled stream resolved the frozen source")
	}
}
