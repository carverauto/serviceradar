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
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	gproto "google.golang.org/protobuf/proto"
)

// grantLiveGateway is a disposable gateway on the agent's real mTLS-less
// gateway address. It records RenewEdgeDeliveryGrants calls and accepts the
// edge-record ingest stream the running agent opens to drain its spool.
type grantLiveGateway struct {
	*startupProbeGateway
	edgev1.UnimplementedEdgeRecordIngestServiceServer

	failRenew   bool
	blockedBulk chan struct{}
	bulkOnce    sync.Once

	mu       sync.Mutex
	requests []grantAsk
	frames   []*edgev1.EdgeDeliveryFrameV1
}

type grantAsk struct {
	spoolID []byte
	records []grantAskRecord
}

type grantAskRecord struct {
	sequence uint64
	body     []byte
}

func (g *grantLiveGateway) RenewEdgeDeliveryGrants(_ context.Context, req *proto.EdgeDeliveryGrantRequest) (*proto.EdgeDeliveryGrantResponse, error) {
	ask := grantAsk{spoolID: append([]byte(nil), req.GetSpoolId()...)}
	for _, rec := range req.GetRecords() {
		ask.records = append(ask.records, grantAskRecord{
			sequence: rec.GetSequence(),
			body:     append([]byte(nil), rec.GetRecordBytes()...),
		})
	}
	g.mu.Lock()
	g.requests = append(g.requests, ask)
	fail := g.failRenew
	g.mu.Unlock()
	if fail {
		return nil, status.Error(codes.Unavailable, "disposable gateway refusing grants")
	}

	now := time.Now()
	notBefore := now.UnixNano()
	expires := now.Add(15 * time.Minute).UnixNano()
	results := make([]*proto.EdgeDeliveryGrantResult, 0, len(ask.records))
	for _, rec := range ask.records {
		record, err := edgerecord.DecodeRecord(rec.body)
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "record %d: %v", rec.sequence, err)
		}
		sum := sha256.Sum256(rec.body)
		results = append(results, &proto.EdgeDeliveryGrantResult{
			Sequence: rec.sequence,
			DeliveryCapability: &edgev1.EdgeSignedCapabilityV1{
				CapabilityVersion: 1,
				IssuerId:          []byte("serviceradar-core"),
				IssuerKeyId:       []byte("test-key-id-0001"),
				Algorithm:         "ed25519",
				NotBeforeUnixNano: notBefore,
				ExpiresAtUnixNano: expires,
				Signature:         make([]byte, 64),
				Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
					EventId:      append([]byte(nil), record.GetEventId()...),
					RecordSha256: sum[:],
					SpoolId:      ask.spoolID,
					Sequence:     rec.sequence,
					Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
						RenewedNotBeforeUnixNano: notBefore,
						RenewedExpiresUnixNano:   expires,
					}},
				}},
			},
		})
	}
	return &proto.EdgeDeliveryGrantResponse{Results: results}, nil
}

func (g *grantLiveGateway) Stream(stream grpc.BidiStreamingServer[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage]) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	open := first.GetLaneOpen()
	if open == nil {
		return status.Error(codes.InvalidArgument, "expected lane_open")
	}
	g.mu.Lock()
	blocked := g.blockedBulk
	g.mu.Unlock()
	if blocked != nil {
		if open.RouteProfile == edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1 {
			g.bulkOnce.Do(func() { close(blocked) })
			<-stream.Context().Done()
			return stream.Context().Err()
		}
		select {
		case <-blocked:
		case <-stream.Context().Done():
			return stream.Context().Err()
		}
	}
	ack := &edgev1.EdgeRecordLaneOpenAck{
		SpoolId:             open.GetSpoolId(),
		SessionNonce:        open.GetSessionNonce(),
		GrantedByteCredits:  open.GetRequestedByteCredits(),
		GrantedFrameCredits: open.GetRequestedFrameCredits(),
		RouteProfile:        open.GetRouteProfile(),
		TrafficClass:        open.GetTrafficClass(),
	}
	if err := stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: ack},
	}); err != nil {
		return err
	}

	resolvedThrough := open.GetFirstUnresolvedSequence() - 1
	var disps []*edgev1.EdgeRecordDisposition
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
		g.mu.Lock()
		g.frames = append(g.frames, gproto.Clone(frame).(*edgev1.EdgeDeliveryFrameV1))
		g.mu.Unlock()

		record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
		if err != nil {
			return status.Error(codes.InvalidArgument, "undecodable record")
		}
		disps = append(disps, &edgev1.EdgeRecordDisposition{
			Sequence: frame.GetSequence(),
			EventId:  record.GetEventId(),
			Kind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
		})
		resolvedThrough = frame.GetSequence()
	}
	return stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: &edgev1.EdgeDeliveryAckV1{
			SpoolId:                 open.GetSpoolId(),
			SessionNonce:            open.GetSessionNonce(),
			ResolvedThroughSequence: resolvedThrough,
			Dispositions:            disps,
		}},
	})
}

func (g *grantLiveGateway) snapshot() (requests []grantAsk, frames []*edgev1.EdgeDeliveryFrameV1) {
	g.mu.Lock()
	defer g.mu.Unlock()
	requests = append([]grantAsk(nil), g.requests...)
	frames = append([]*edgev1.EdgeDeliveryFrameV1(nil), g.frames...)
	return requests, frames
}

func listenGrantGateway(t *testing.T, failRenew bool) (*grantLiveGateway, string) {
	t.Helper()
	lis, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	gw := &grantLiveGateway{startupProbeGateway: &startupProbeGateway{}, failRenew: failRenew}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	edgev1.RegisterEdgeRecordIngestServiceServer(server, gw)
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(func() {
		server.Stop()
		_ = lis.Close()
	})
	return gw, lis.Addr().String()
}

func spooledEdgeRecord(t *testing.T, expires time.Time) spooledRecord {
	t.Helper()
	eventID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("event id: %v", err)
	}
	body, err := gproto.Marshal(&edgev1.EdgeRecordV1{
		EventId:              eventID,
		ProductionCapability: &edgev1.EdgeSignedCapabilityV1{ExpiresAtUnixNano: expires.UnixNano()},
	})
	if err != nil {
		t.Fatalf("marshal record: %v", err)
	}
	return spooledRecord{eventID: eventID, body: body}
}

// startGrantDrainAgent runs the agent binary the way an operator does, pointed
// at a disposable gateway, with one lapsed record and one record still inside
// its production grant.
func startGrantDrainAgent(t *testing.T, addr string, lapsed, current spooledRecord) *agentOutput {
	t.Helper()
	binaryPath := agentTestBinary(t)
	root := t.TempDir()
	checkers := filepath.Join(root, "checkers")
	if err := os.MkdirAll(checkers, 0o755); err != nil {
		t.Fatalf("checkers dir: %v", err)
	}
	spoolDir := filepath.Join(root, "spool")
	commitSpool(t, spoolDir, []spooledRecord{lapsed, current})

	configPath := filepath.Join(root, "agent.json")
	config := fmt.Sprintf(`{
		"agent_id": "edge-grant-renewal",
		"checkers_dir": %q,
		"partition": "default",
		"gateway_addr": %q,
		"push_interval": "1h",
		"gateway_security": {"mode": "none"},
		"logging": {"level": "info", "output": "stdout"},
		"edge_record_sender": {
			"spool_dir": %q,
			"poll_interval": "1s"
		}
	}`, checkers, addr, spoolDir)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, binaryPath, "--config", configPath)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "SR_ALLOW_INSECURE=true")
	logs := &agentOutput{}
	cmd.Stdout = logs
	cmd.Stderr = logs
	if err := cmd.Start(); err != nil {
		t.Fatalf("start agent: %v", err)
	}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_, _ = cmd.Process.Wait()
	})
	return logs
}

func waitForGrantDrain(t *testing.T, gw *grantLiveGateway, wantAsk bool) ([]grantAsk, []*edgev1.EdgeDeliveryFrameV1) {
	t.Helper()
	deadline := time.Now().Add(25 * time.Second)
	var requests []grantAsk
	var frames []*edgev1.EdgeDeliveryFrameV1
	for time.Now().Before(deadline) {
		requests, frames = gw.snapshot()
		asked := !wantAsk || len(requests) > 0
		if asked && framesCoverBothSequences(frames) {
			return requests, frames
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("agent did not drain within 25s: requests=%d frames=%d", len(requests), len(frames))
	return nil, nil
}

func framesCoverBothSequences(frames []*edgev1.EdgeDeliveryFrameV1) bool {
	var saw1, saw2 bool
	for _, frame := range frames {
		switch frame.GetSequence() {
		case 1:
			saw1 = true
		case 2:
			saw2 = true
		}
	}
	return saw1 && saw2
}

// The running agent asks the gateway only for the record whose production
// grant has lapsed, sends that record's exact bytes, and attaches the grant
// it got. The record still inside its production window is delivered with no
// grant and is not named in the renewal request.
func TestRunningAgentRenewsALapsedRecordAndLeavesACurrentOne(t *testing.T) {
	now := time.Now()
	lapsed := spooledEdgeRecord(t, now.Add(-2*time.Hour))
	current := spooledEdgeRecord(t, now.Add(2*time.Hour))
	gw, addr := listenGrantGateway(t, false)
	logs := startGrantDrainAgent(t, addr, lapsed, current)
	requests, frames := waitForGrantDrain(t, gw, true)

	for _, ask := range requests {
		if len(ask.spoolID) != 16 {
			t.Fatalf("grant request spool id length = %d, want 16", len(ask.spoolID))
		}
		if len(ask.records) != 1 || ask.records[0].sequence != 1 || !bytes.Equal(ask.records[0].body, lapsed.body) {
			t.Fatalf("grant request records = %+v, want only the lapsed record at sequence 1", ask.records)
		}
	}
	for _, frame := range frames {
		switch frame.GetSequence() {
		case 1:
			dc := frame.GetDeliveryCapability()
			if dc.GetDelivery().GetSequence() != 1 || !bytes.Equal(dc.GetDelivery().GetRecordSha256(), sha256Sum(lapsed.body)) {
				t.Fatalf("lapsed frame missing its delivery grant: %v", dc)
			}
			if !bytes.Equal(frame.GetRecordBytes(), lapsed.body) {
				t.Fatal("lapsed frame bytes differ from the spooled record")
			}
		case 2:
			if frame.GetDeliveryCapability() != nil {
				t.Fatal("record under a current production grant was sent with a delivery grant")
			}
		}
	}
	t.Logf("grant requests=%d frames=%d\n%s", len(requests), len(frames), logs.snapshot())
}

// A gateway that will not renew does not stall the agent. The backlog is
// still delivered, without a grant, and the operator log names the failure.
func TestRunningAgentStillDeliversWhenGrantRenewalIsUnavailable(t *testing.T) {
	now := time.Now()
	lapsed := spooledEdgeRecord(t, now.Add(-2*time.Hour))
	current := spooledEdgeRecord(t, now.Add(2*time.Hour))
	gw, addr := listenGrantGateway(t, true)
	logs := startGrantDrainAgent(t, addr, lapsed, current)
	requests, frames := waitForGrantDrain(t, gw, true)

	if len(requests) == 0 {
		t.Fatal("agent did not ask for a grant")
	}
	for _, frame := range frames {
		if frame.GetDeliveryCapability() != nil {
			t.Fatalf("sequence %d carried a grant after renewal failed", frame.GetSequence())
		}
	}
	// The sender logs the renewal failure when its run ends, which can be
	// after the gateway has already received both frames.
	waitForLog(t, logs, "could not obtain delivery grants", 25*time.Second)
	t.Logf("renewal unavailable; requests=%d frames=%d still delivered", len(requests), len(frames))
}

func sha256Sum(b []byte) []byte {
	sum := sha256.Sum256(b)
	return sum[:]
}
