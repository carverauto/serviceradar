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

package netprobe

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const testDNSProtocol = "dns"

// streaming event delivery; the branching mirrors the frame types under test and keeping
// them in one test preserves ordering guarantees that splitting into subtests would lose.
//
//nolint:gocyclo // end-to-end integration scenario exercising ping, apply_config, and
func TestClientPingApplyConfigAndEvents(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			ping := frame.GetPing()
			if ping == nil {
				t.Errorf("first frame payload = %T, want ping", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected ping")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_PingAck{
					PingAck: &netprobepb.PingAck{
						SentAtUnixNano:                     ping.GetSentAtUnixNano(),
						AckedAtUnixNano:                    ping.GetSentAtUnixNano() + 1,
						FingerprintEngineVersion:           "test-engine",
						P0FCorpusRevision:                  "p0f-rev",
						ServiceradarAdditionsRevision:      "sr-additions-rev",
						Ja4SpecRevision:                    "ja4-rev",
						MuonfpCorpusRevision:               "muonfp-rev",
						RecogCorpusRevision:                "recog-rev",
						SatoriCorpusRevision:               "satori-rev",
						ServiceradarRecogAdditionsRevision: "sr-recog-rev",
						RecogCorpusLoaded:                  true,
					},
				},
			}
		})
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			if frame.GetApplyConfig() == nil {
				t.Errorf("second frame payload = %T, want apply_config", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected apply_config")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_ConfigAck{
					ConfigAck: &netprobepb.ConfigAck{ConfigHash: "hash-1"},
				},
			}
		})
		err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_FingerprintEvent{
				FingerprintEvent: &netprobepb.FingerprintEvent{Ip: "192.0.2.10"},
			},
		})
		if err != nil {
			t.Errorf("write event frame: %v", err)
		}
		err = writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_DpiEvent{
				DpiEvent: &netprobepb.DpiEvent{Protocol: testDNSProtocol},
			},
		})
		if err != nil {
			t.Errorf("write DPI event frame: %v", err)
		}
		err = writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_FlowAttributionEvent{
				FlowAttributionEvent: &netprobepb.FlowAttributionEvent{LocalIp: "192.0.2.10", Pid: 123},
			},
		})
		if err != nil {
			t.Errorf("write flow attribution event frame: %v", err)
		}
		err = writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_ProcessSnapshot{
				ProcessSnapshot: &netprobepb.ProcessSnapshot{Fingerprint: "fp-1"},
			},
		})
		if err != nil {
			t.Errorf("write process snapshot frame: %v", err)
		}
	}()

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	if err := client.Ping(ctx); err != nil {
		t.Fatalf("Ping() error = %v", err)
	}
	if got := client.FingerprintEngineVersion(); got != "test-engine" {
		t.Fatalf("FingerprintEngineVersion() = %q, want test-engine", got)
	}
	if got := client.P0fCorpusRevision(); got != "p0f-rev" {
		t.Fatalf("P0fCorpusRevision() = %q, want p0f-rev", got)
	}
	if got := client.ServiceRadarAdditionsRevision(); got != "sr-additions-rev" {
		t.Fatalf("ServiceRadarAdditionsRevision() = %q, want sr-additions-rev", got)
	}
	if got := client.JA4SpecRevision(); got != "ja4-rev" {
		t.Fatalf("JA4SpecRevision() = %q, want ja4-rev", got)
	}
	if got := client.MuonFPCorpusRevision(); got != "muonfp-rev" {
		t.Fatalf("MuonFPCorpusRevision() = %q, want muonfp-rev", got)
	}
	if got := client.RecogCorpusRevision(); got != "recog-rev" {
		t.Fatalf("RecogCorpusRevision() = %q, want recog-rev", got)
	}
	if got := client.SatoriCorpusRevision(); got != "satori-rev" {
		t.Fatalf("SatoriCorpusRevision() = %q, want satori-rev", got)
	}
	if got := client.ServiceRadarRecogAdditionsRevision(); got != "sr-recog-rev" {
		t.Fatalf("ServiceRadarRecogAdditionsRevision() = %q, want sr-recog-rev", got)
	}
	if !client.RecogCorpusLoaded() {
		t.Fatal("RecogCorpusLoaded() = false, want true")
	}

	hash, err := client.ApplyConfig(ctx, &netprobepb.VisibilityAgentConfig{
		Enabled:           true,
		CaptureInterfaces: []string{"en0"},
	})
	if err != nil {
		t.Fatalf("ApplyConfig() error = %v", err)
	}
	if hash != "hash-1" {
		t.Fatalf("ApplyConfig() hash = %q, want hash-1", hash)
	}

	select {
	case event := <-client.Events():
		if event.GetIp() != "192.0.2.10" {
			t.Fatalf("event IP = %q, want 192.0.2.10", event.GetIp())
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for fingerprint event")
	}
	select {
	case event := <-client.DpiEvents():
		if event.GetProtocol() != testDNSProtocol {
			t.Fatalf("DPI event protocol = %q, want dns", event.GetProtocol())
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for DPI event")
	}
	select {
	case event := <-client.FlowAttributionEvents():
		if event.GetPid() != 123 {
			t.Fatalf("flow attribution event PID = %d, want 123", event.GetPid())
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for flow attribution event")
	}
	select {
	case snapshot := <-client.ProcessSnapshots():
		if snapshot.GetFingerprint() != "fp-1" {
			t.Fatalf("process snapshot fingerprint = %q, want fp-1", snapshot.GetFingerprint())
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for process snapshot")
	}

	_ = client.Close()
	<-serverDone
}

// backpressureTestCase wires a typed-event-stream backpressure test into the
// shared runBackpressureTest helper. Each typed event stream (DPI, process
// snapshots, fingerprint events, flow attribution) exercises the same control
// flow — write two frames into a length-1 buffer, expect exactly one drop,
// then verify the first frame remained queued — so they are expressed as
// table-driven cases rather than duplicating the test body.
type backpressureTestCase struct {
	name             string
	stream           string
	writeFrame       func(t *testing.T, conn net.Conn, i int) error
	droppedCount     func(c *Client) uint64
	consumeAndVerify func(t *testing.T, c *Client)
	droppedLabel     string
}

func runBackpressureTest(t *testing.T, tc backpressureTestCase) {
	t.Helper()

	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	recorder := &testEventDropRecorder{}
	client := NewClient(clientConn, 1, WithEventDropRecorder(recorder))
	defer func() { _ = client.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		for i := 0; i < 2; i++ {
			if err := tc.writeFrame(t, serverConn, i); err != nil {
				t.Errorf("write %s frame %d: %v", tc.stream, i, err)
				return
			}
		}
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			ping := frame.GetPing()
			if ping == nil {
				t.Errorf("frame payload = %T, want ping", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected ping")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_PingAck{
					PingAck: &netprobepb.PingAck{SentAtUnixNano: ping.GetSentAtUnixNano()},
				},
			}
		})
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	waitFor(t, ctx, func() bool {
		return tc.droppedCount(client) == 1
	})
	if err := client.Ping(ctx); err != nil {
		t.Fatalf("Ping() after backpressure error = %v", err)
	}

	tc.consumeAndVerify(t, client)

	if got := tc.droppedCount(client); got != 1 {
		t.Fatalf("%s = %d, want 1", tc.droppedLabel, got)
	}
	recorder.assertOne(t, tc.stream, EventDropBackpressure)

	_ = client.Close()
	<-serverDone
}

func TestClientDropsDPIEventsOnBackpressure(t *testing.T) {
	runBackpressureTest(t, backpressureTestCase{
		name:   "dpi",
		stream: EventStreamDPI,
		writeFrame: func(_ *testing.T, conn net.Conn, _ int) error {
			return writeFrame(conn, &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_DpiEvent{
					DpiEvent: &netprobepb.DpiEvent{Protocol: testDNSProtocol},
				},
			})
		},
		droppedCount: func(c *Client) uint64 { return c.DroppedDPIEvents() },
		consumeAndVerify: func(t *testing.T, c *Client) {
			t.Helper()
			select {
			case event := <-c.DpiEvents():
				if event.GetProtocol() != testDNSProtocol {
					t.Fatalf("queued DPI event protocol = %q, want dns", event.GetProtocol())
				}
			default:
				t.Fatal("expected first DPI event to remain queued")
			}
		},
		droppedLabel: "DroppedDPIEvents()",
	})
}

func TestClientMatchBanners(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			batch := frame.GetBannerBatch()
			if batch == nil || len(batch.GetObservations()) != 1 {
				t.Errorf("frame payload = %T, want one banner observation", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected banner_batch")
			}

			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_BannerMatchBatch{
					BannerMatchBatch: &netprobepb.BannerMatchBatch{
						Matches: []*netprobepb.BannerMatch{{
							ObservationId: batch.GetObservations()[0].GetObservationId(),
							CorpusLabel:   "recog",
							Product:       "OpenSSH",
							Confidence:    0.95,
						}},
					},
				},
			}
		})
	}()

	client := NewClient(clientConn, 1)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	matches, err := client.MatchBanners(ctx, &netprobepb.BannerBatch{
		Observations: []*netprobepb.BannerObservation{{
			ObservationId: 7,
			Host:          "192.0.2.10",
			Port:          22,
			Protocol:      "ssh",
			BannerBytes:   []byte("SSH-2.0-OpenSSH_9.6"),
			Source:        "sweep_active",
		}},
	})
	if err != nil {
		t.Fatalf("MatchBanners() error = %v", err)
	}
	if len(matches.GetMatches()) != 1 || matches.GetMatches()[0].GetObservationId() != 7 {
		t.Fatalf("matches = %#v, want observation 7", matches.GetMatches())
	}

	_ = client.Close()
	<-serverDone
}

func TestClientIngestExternalFlow(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			record := frame.GetExternalFlowRecord()
			if record == nil || record.GetExternalFlowId() != 42 {
				t.Errorf("frame payload = %T, want external_flow_record 42", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected external_flow_record")
			}

			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_ExternalFlowAck{
					ExternalFlowAck: &netprobepb.ExternalFlowAck{Accepted: 1, Matched: 1},
				},
			}
		})
	}()

	client := NewClient(clientConn, 1)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	ack, err := client.IngestExternalFlow(ctx, externalFlowRecord())
	if err != nil {
		t.Fatalf("IngestExternalFlow() error = %v", err)
	}
	if ack.GetAccepted() != 1 || ack.GetMatched() != 1 {
		t.Fatalf("external flow ack = %#v, want accepted+matched", ack)
	}

	_ = client.Close()
	<-serverDone
}

func TestClientStreamExternalFlowUsesFireAndForgetFrame(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		frame, err := readFrame(serverConn)
		if err != nil {
			t.Errorf("read external flow frame: %v", err)
			return
		}
		if frame.GetSequence() != 0 {
			t.Errorf("external flow sequence = %d, want 0", frame.GetSequence())
		}
		if frame.GetExternalFlowRecord().GetExternalFlowId() != 42 {
			t.Errorf("external_flow_id = %d, want 42", frame.GetExternalFlowRecord().GetExternalFlowId())
		}
	}()

	client := NewClient(clientConn, 1)
	defer func() { _ = client.Close() }()

	if err := client.StreamExternalFlow(externalFlowRecord()); err != nil {
		t.Fatalf("StreamExternalFlow() error = %v", err)
	}

	_ = client.Close()
	<-serverDone
}

func TestClientReadsFlowAttributionBatch(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_FlowAttributionBatch{
				FlowAttributionBatch: &netprobepb.FlowAttributionEventBatch{
					Events: []*netprobepb.FlowAttributionEvent{
						{LocalIp: "192.0.2.10", Pid: 123},
						{LocalIp: "192.0.2.11", Pid: 124},
					},
				},
			},
		})
		if err != nil {
			t.Errorf("write flow attribution batch: %v", err)
		}
	}()

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	for _, wantPID := range []uint32{123, 124} {
		select {
		case event := <-client.FlowAttributionEvents():
			if event.GetPid() != wantPID {
				t.Fatalf("flow attribution event PID = %d, want %d", event.GetPid(), wantPID)
			}
		case <-ctx.Done():
			t.Fatalf("timed out waiting for flow attribution event PID %d", wantPID)
		}
	}

	_ = client.Close()
	<-serverDone
}

func TestClientDropsFlowAttributionEventsOnBackpressure(t *testing.T) {
	runBackpressureTest(t, backpressureTestCase{
		name:   "flow_attribution",
		stream: EventStreamFlowAttr,
		writeFrame: func(_ *testing.T, conn net.Conn, i int) error {
			return writeFrame(conn, &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_FlowAttributionEvent{
					FlowAttributionEvent: &netprobepb.FlowAttributionEvent{LocalIp: "192.0.2.10", Pid: uint32(123 + i)},
				},
			})
		},
		droppedCount: func(c *Client) uint64 { return c.DroppedFlowAttributionEvents() },
		consumeAndVerify: func(t *testing.T, c *Client) {
			t.Helper()
			select {
			case event := <-c.FlowAttributionEvents():
				if event.GetPid() != 123 {
					t.Fatalf("queued flow attribution event PID = %d, want 123", event.GetPid())
				}
			default:
				t.Fatal("expected first flow attribution event to remain queued")
			}
		},
		droppedLabel: "DroppedFlowAttributionEvents()",
	})
}

func TestClientDropsProcessSnapshotsOnBackpressure(t *testing.T) {
	runBackpressureTest(t, backpressureTestCase{
		name:   "process_snapshot",
		stream: EventStreamProcessSnap,
		writeFrame: func(_ *testing.T, conn net.Conn, _ int) error {
			return writeFrame(conn, &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_ProcessSnapshot{
					ProcessSnapshot: &netprobepb.ProcessSnapshot{Fingerprint: "fp"},
				},
			})
		},
		droppedCount: func(c *Client) uint64 { return c.DroppedProcessSnapshots() },
		consumeAndVerify: func(t *testing.T, c *Client) {
			t.Helper()
			select {
			case snapshot := <-c.ProcessSnapshots():
				if snapshot.GetFingerprint() != "fp" {
					t.Fatalf("queued process snapshot fingerprint = %q, want fp", snapshot.GetFingerprint())
				}
			default:
				t.Fatal("expected first process snapshot to remain queued")
			}
		},
		droppedLabel: "DroppedProcessSnapshots()",
	})
}

//nolint:unparam // code parameterized for future error-code coverage in tests
func errorResponse(sequence uint64, code, message string) *netprobepb.NetprobeFrame {
	return &netprobepb.NetprobeFrame{
		Sequence: sequence,
		Payload: &netprobepb.NetprobeFrame_Error{
			Error: &netprobepb.ErrorFrame{Code: code, Message: message},
		},
	}
}

func externalFlowRecord() *netprobepb.ExternalFlowRecord {
	return &netprobepb.ExternalFlowRecord{
		ExternalFlowId:    42,
		SourceIp:          []byte{198, 51, 100, 20},
		DestinationIp:     []byte{192, 0, 2, 10},
		SourcePort:        443,
		DestinationPort:   49152,
		TransportProtocol: "tcp",
		TimeFlowEndNs:     123,
		Bytes:             4096,
		Packets:           9,
	}
}

func TestClientReturnsErrorFrame(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	go handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
		return &netprobepb.NetprobeFrame{
			Sequence: frame.GetSequence(),
			Payload: &netprobepb.NetprobeFrame_Error{
				Error: &netprobepb.ErrorFrame{Code: "invalid_config", Message: "bad config"},
			},
		}
	})

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	_, err := client.ApplyConfig(context.Background(), &netprobepb.VisibilityAgentConfig{})
	var errorFrame ErrorFrame
	if !errors.As(err, &errorFrame) {
		t.Fatalf("ApplyConfig() error = %T %v, want ErrorFrame", err, err)
	}
	if errorFrame.Code != "invalid_config" {
		t.Fatalf("ErrorFrame.Code = %q, want invalid_config", errorFrame.Code)
	}
}

func TestClientDropsFingerprintEventsOnBackpressure(t *testing.T) {
	runBackpressureTest(t, backpressureTestCase{
		name:   "fingerprint",
		stream: EventStreamFingerprint,
		writeFrame: func(_ *testing.T, conn net.Conn, _ int) error {
			return writeFrame(conn, &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_FingerprintEvent{
					FingerprintEvent: &netprobepb.FingerprintEvent{Ip: "192.0.2.10"},
				},
			})
		},
		droppedCount: func(c *Client) uint64 { return c.DroppedFingerprintEvents() },
		consumeAndVerify: func(t *testing.T, c *Client) {
			t.Helper()
			select {
			case event := <-c.Events():
				if event.GetIp() != "192.0.2.10" {
					t.Fatalf("queued event IP = %q, want 192.0.2.10", event.GetIp())
				}
			default:
				t.Fatal("expected first fingerprint event to remain queued")
			}
		},
		droppedLabel: "DroppedFingerprintEvents()",
	})
}

func TestClientCloseClosesEventsFromReadLoop(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	client := NewClient(clientConn, 4)
	_ = client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	select {
	case _, ok := <-client.Events():
		if ok {
			t.Fatal("Events() remained open after Close()")
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for Events() to close")
	}
}

func TestClientNilConnectionClosesSafely(t *testing.T) {
	client := NewClient(nil, 4)

	if err := client.Ping(context.Background()); !errors.Is(err, ErrNilConnection) {
		t.Fatalf("Ping() error = %v, want %v", err, ErrNilConnection)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	select {
	case _, ok := <-client.Events():
		if ok {
			t.Fatal("Events() remained open after nil connection")
		}
	default:
		t.Fatal("Events() was not closed for nil connection")
	}
	select {
	case _, ok := <-client.DpiEvents():
		if ok {
			t.Fatal("DpiEvents() remained open after nil connection")
		}
	default:
		t.Fatal("DpiEvents() was not closed for nil connection")
	}
	select {
	case _, ok := <-client.FlowAttributionEvents():
		if ok {
			t.Fatal("FlowAttributionEvents() remained open after nil connection")
		}
	default:
		t.Fatal("FlowAttributionEvents() was not closed for nil connection")
	}
	select {
	case _, ok := <-client.ProcessSnapshots():
		if ok {
			t.Fatal("ProcessSnapshots() remained open after nil connection")
		}
	default:
		t.Fatal("ProcessSnapshots() was not closed for nil connection")
	}
}

func handleTestFrame(t *testing.T, conn net.Conn, handler func(*netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame) {
	t.Helper()

	frame, err := readFrame(conn)
	if err != nil {
		t.Errorf("read test frame: %v", err)
		return
	}
	if err := writeFrame(conn, handler(frame)); err != nil {
		t.Errorf("write test response: %v", err)
	}
}

func waitFor(t *testing.T, ctx context.Context, ready func() bool) {
	t.Helper()

	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()

	for {
		if ready() {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatalf("timed out waiting: %v", ctx.Err())
		case <-ticker.C:
		}
	}
}

type testEventDropRecorder struct {
	mu     sync.Mutex
	events []eventDrop
}

type eventDrop struct {
	stream string
	reason string
}

func (r *testEventDropRecorder) IncEventDrop(stream, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.events = append(r.events, eventDrop{stream: stream, reason: reason})
}

func (r *testEventDropRecorder) assertOne(t *testing.T, stream, reason string) {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()

	if len(r.events) != 1 {
		t.Fatalf("recorded event drops = %d, want 1", len(r.events))
	}
	if r.events[0].stream != stream || r.events[0].reason != reason {
		t.Fatalf("recorded event drop = (%q, %q), want (%q, %q)", r.events[0].stream, r.events[0].reason, stream, reason)
	}
}

// TestClientRecordsUnhandledUnsolicitedFrames pins the loud-unknown-arm
// behaviour required by GitHub #4026.
//
// Before this, the unsolicited branch of readLoop was a chain of `if x != nil`
// with no default: a frame carrying an arm the agent does not handle fell
// through to `continue` with no log, no metric and no recordEventDrop. That
// matters most in exactly the case it is hardest to notice -- a netprobe newer
// than its agent, emitting an arm the agent was built without, losing every
// such frame silently on both sides.
func TestClientRecordsUnhandledUnsolicitedFrames(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	recorder := &testEventDropRecorder{}
	client := NewClient(clientConn, 4, WithEventDropRecorder(recorder))
	defer func() { _ = client.Close() }()

	// PcapngBlock is a real arm the agent has no handler for. Sequence 0 marks
	// it unsolicited, which is the path with no default branch.
	if err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_PcapngBlock{
			PcapngBlock: &netprobepb.PcapngBlock{SessionId: "session-1"},
		},
	}); err != nil {
		t.Fatalf("write unsolicited frame: %v", err)
	}

	deadline := time.After(2 * time.Second)
	for client.DroppedUnknownFrames() != 1 {
		select {
		case <-deadline:
			t.Fatalf("DroppedUnknownFrames() = %d, want 1", client.DroppedUnknownFrames())
		case <-time.After(5 * time.Millisecond):
		}
	}

	recorder.assertOne(t, EventStreamUnknown, EventDropUnhandledArm)
}

// TestClientDoesNotRecordHandledUnsolicitedFrames is the negative control: a
// counter that only ever goes up would pass the test above while reporting
// every healthy frame as unknown.
func TestClientDoesNotRecordHandledUnsolicitedFrames(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	recorder := &testEventDropRecorder{}
	client := NewClient(clientConn, 4, WithEventDropRecorder(recorder))
	defer func() { _ = client.Close() }()

	if err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_DpiEvent{
			DpiEvent: &netprobepb.DpiEvent{Protocol: testDNSProtocol},
		},
	}); err != nil {
		t.Fatalf("write dpi frame: %v", err)
	}

	select {
	case <-client.DpiEvents():
	case <-time.After(2 * time.Second):
		t.Fatal("expected the DPI event to be delivered")
	}

	if got := client.DroppedUnknownFrames(); got != 0 {
		t.Fatalf("DroppedUnknownFrames() = %d after a handled frame, want 0", got)
	}
}
