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
	sp, err := spool.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	for _, tc := range []struct{ name, message string }{
		{"disabled", ""},
		{"address", "Edge record sender enabled without a gateway address"},
		{"spool", "Edge record sender enabled without a spool_dir"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "spool")
			cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{
				Enabled: true, GatewayAddr: "127.0.0.1:1", SpoolDir: dir,
				Security: &models.SecurityConfig{Mode: models.SecurityModeNone},
			}}
			switch tc.name {
			case "disabled":
				cfg.EdgeRecordSender.Enabled = false
			case "address":
				cfg.EdgeRecordSender.GatewayAddr = ""
			case "spool":
				cfg.EdgeRecordSender.SpoolDir = ""
			}
			var output bytes.Buffer
			log := &senderGuardLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			mustReturnPromptly(t, func() { runEdgeRecordSender(ctx, cfg, sp, log) })
			if tc.message == "" {
				if output.Len() != 0 {
					t.Fatalf("disabled sender emitted error: %s", output.String())
				}
			} else {
				var event struct {
					Message string `json:"message"`
				}
				if err := json.Unmarshal(output.Bytes(), &event); err != nil {
					t.Fatal(err)
				}
				if event.Message != tc.message {
					t.Fatalf("message = %q, want %q", event.Message, tc.message)
				}
			}
			if _, err := os.Stat(dir); !os.IsNotExist(err) {
				t.Fatalf("guard created spool: %v", err)
			}
		})
	}
}

func TestOpenEdgeRecordSpoolRejectsMissingDirectory(t *testing.T) {
	_, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{Enabled: true}})
	if err == nil {
		t.Fatal("enabled sender accepted missing spool directory")
	}
}

func TestOpenEdgeRecordSpoolRefusesAdmissionAtBudgetAfterRestart(t *testing.T) {
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{Enabled: true, SweepEnabled: true, SpoolDir: t.TempDir(), MaxBytes: 4 << 20}}
	sp, err := openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = sp.Append(make([]byte, 16), make([]byte, 1<<20)); err != nil {
		t.Fatal(err)
	}
	if err = sp.Close(); err != nil {
		t.Fatal(err)
	}
	sp, err = openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	if _, err = sp.Append(make([]byte, 16), make([]byte, 1<<20)); !errors.Is(err, spool.ErrAdmissionRefused) {
		t.Fatalf("second append=%v, want byte-budget refusal", err)
	}
	records, err := sp.Unresolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("refused append changed spool: %d records", len(records))
	}
}

func TestRunEdgeRecordSenderRetriesSetupUntilSpoolDirIsCreatable(t *testing.T) {
	sp, err := spool.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(blocker, "spool")
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{
		Enabled: true, GatewayAddr: "127.0.0.1:1", SpoolDir: dir,
		Security: &models.SecurityConfig{Mode: models.SecurityModeNone},
	}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runEdgeRecordSender(ctx, cfg, sp, logger.NewTestLogger())
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("sender stopped after its first setup failure")
	case <-time.After(200 * time.Millisecond):
	}
	idPath := filepath.Join(dir, "spool_id")
	if _, err := os.Stat(idPath); err == nil {
		t.Fatal("setup succeeded while the spool directory could not be created")
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(idPath); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("sender never retried setup after the spool directory became creatable")
		}
		time.Sleep(50 * time.Millisecond)
	}

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("sender did not stop after cancellation")
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
