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
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/grpc"
	goproto "google.golang.org/protobuf/proto"
)

// A running agent, spoken to the way core does (a control stream of lease
// chunks), installs only a plan-carrying push, refuses a push whose check-set
// grammar it cannot verify, and keeps the installed lease across that refusal,
// a slot-less same-lease push, and a process restart. The oracle is the lease
// file the agent rewrites and the ack it sends back, not the store's internals.
func TestRunningAgentInstallsPlanCarriedSweepLeases(t *testing.T) {
	binary := agentTestBinary(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	root := t.TempDir()
	leaseDir := filepath.Join(root, "sweep-leases")
	if err := os.MkdirAll(leaseDir, 0o755); err != nil {
		t.Fatalf("lease dir: %v", err)
	}
	staleGroup := "22222222-3333-4444-8555-666666666666"
	heldGroup := "33333333-4444-4555-8666-777777777777"
	writeLeaseFile(t, leaseDir, staleGroup, prePlanSlotLease(staleGroup))
	if err := os.WriteFile(filepath.Join(leaseDir, staleGroup+".executed.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatalf("stale sidecar: %v", err)
	}
	writeLeaseFile(t, leaseDir, heldGroup, slotlessLease(heldGroup, fixedID("aaaaaaaaaaaabbbb"), time.Now()))

	gw := newPlanLeaseGateway()
	lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	go func() {
		if serveErr := server.Serve(lis); serveErr != nil && !strings.Contains(serveErr.Error(), "use of closed") {
			t.Logf("gateway serve ended: %v", serveErr)
		}
	}()
	t.Cleanup(server.Stop)

	group := "11111111-2222-3333-4444-555555555555"
	leaseID := fixedID("6666666677774888")
	otherLeaseID := fixedID("7777777788884999")
	assignment := fixedID("aaaaaaaabbbb4ccc")
	slotID := fixedID("1212121234344565")
	otherSlotID := fixedID("1313131335354575")
	now := time.Now()
	slotAt := now.Add(time.Hour)

	logs := &agentOutput{}
	cmd := startPlanLeaseAgent(t, ctx, binary, root, lis.Addr().String(), logs)
	hello := gw.waitHello(t, logs)
	requireCapabilities(t, hello, "sweep_lease_v1", "sweep_lease_plan_checks:v1")
	t.Logf("control hello carries sweep_lease_v1 and sweep_lease_plan_checks:v1")

	if _, statErr := os.Stat(filepath.Join(leaseDir, staleGroup+".pb")); !os.IsNotExist(statErr) {
		t.Fatalf("pre-plan slot lease still on disk after startup: %v", statErr)
	}
	if _, statErr := os.Stat(filepath.Join(leaseDir, staleGroup+".executed.json")); !os.IsNotExist(statErr) {
		t.Fatalf("pre-plan sidecar still on disk after startup: %v", statErr)
	}
	held := readLeaseFile(t, leaseDir, heldGroup)
	if held.GetLeaseVersion() != 1 || len(held.GetSlots()) != 0 {
		t.Fatalf("slot-less held lease = version %d slots %d, want version 1 and no slots", held.GetLeaseVersion(), len(held.GetSlots()))
	}
	t.Logf("startup discarded the pre-plan slot lease and kept the slot-less lease")

	installed := gw.push(t, logs, group, carriedLease(group, leaseID, assignment, slotID, slotAt))
	if !installed.GetInstalled() || installed.GetInstalledSlotCount() != 1 || installed.GetError() != "" {
		t.Fatalf("v2 install ack = installed:%t slots:%d err:%q", installed.GetInstalled(), installed.GetInstalledSlotCount(), installed.GetError())
	}
	onDisk := readLeaseFile(t, leaseDir, group)
	if onDisk.GetLeaseVersion() != edgerecord.SweepLeaseCheckSetsVersion || !bytes.Equal(onDisk.GetSlots()[0].GetExecutionId(), slotID) {
		t.Fatalf("installed lease = version %d execution %x", onDisk.GetLeaseVersion(), onDisk.GetSlots()[0].GetExecutionId())
	}
	t.Logf("v2 push installed lease_version %d with the carried slot", onDisk.GetLeaseVersion())

	broken := carriedLease(group, leaseID, assignment, slotID, slotAt)
	broken.CheckSets[0].DigestVersion = 2
	refused := gw.push(t, logs, group, broken)
	if refused.GetInstalled() || !strings.Contains(refused.GetError(), "digest_version") {
		t.Fatalf("unknown digest ack = installed:%t err:%q", refused.GetInstalled(), refused.GetError())
	}
	afterRefusal := readLeaseFile(t, leaseDir, group)
	if !goproto.Equal(onDisk, afterRefusal) {
		t.Fatalf("refused push changed the installed lease")
	}
	t.Logf("unknown digest_version refused the push and left the installed lease in place: %s", refused.GetError())

	kept := gw.push(t, logs, group, slotlessLease(group, leaseID, now))
	if !kept.GetInstalled() || kept.GetInstalledSlotCount() != 1 {
		t.Fatalf("slot-less same-lease ack = installed:%t slots:%d err:%q", kept.GetInstalled(), kept.GetInstalledSlotCount(), kept.GetError())
	}
	merged := readLeaseFile(t, leaseDir, group)
	if merged.GetLeaseVersion() != edgerecord.SweepLeaseCheckSetsVersion || len(merged.GetSlots()) != 1 || len(merged.GetCheckSets()) != 1 {
		t.Fatalf("after slot-less push: version %d slots %d check sets %d", merged.GetLeaseVersion(), len(merged.GetSlots()), len(merged.GetCheckSets()))
	}
	if !bytes.Equal(merged.GetSlots()[0].GetExecutionId(), slotID) {
		t.Fatalf("slot-less push dropped the carried slot")
	}
	t.Logf("slot-less same-lease push kept lease_version 2, the slot, and its check set")

	stopPlanLeaseAgent(cmd)
	gw.waitStreamEnd(t, logs)
	cmd = startPlanLeaseAgent(t, ctx, binary, root, lis.Addr().String(), logs)
	reloadedHello := gw.waitHello(t, logs)
	requireCapabilities(t, reloadedHello, "sweep_lease_v1", "sweep_lease_plan_checks:v1")
	reloaded := gw.push(t, logs, group, slotlessLease(group, leaseID, now))
	if !reloaded.GetInstalled() || reloaded.GetInstalledSlotCount() != 1 {
		t.Fatalf("reload ack = installed:%t slots:%d err:%q", reloaded.GetInstalled(), reloaded.GetInstalledSlotCount(), reloaded.GetError())
	}
	survived := readLeaseFile(t, leaseDir, group)
	if survived.GetLeaseVersion() != edgerecord.SweepLeaseCheckSetsVersion || !bytes.Equal(survived.GetSlots()[0].GetExecutionId(), slotID) {
		t.Fatalf("reloaded lease = version %d execution %x", survived.GetLeaseVersion(), survived.GetSlots()[0].GetExecutionId())
	}
	t.Logf("after restart a same-lease slot-less push still resolved the carried slot at lease_version 2")

	replaced := gw.push(t, logs, group, carriedLease(group, otherLeaseID, assignment, otherSlotID, slotAt.Add(time.Hour)))
	if !replaced.GetInstalled() || replaced.GetInstalledSlotCount() != 1 {
		t.Fatalf("replacement ack = installed:%t slots:%d err:%q", replaced.GetInstalled(), replaced.GetInstalledSlotCount(), replaced.GetError())
	}
	fresh := readLeaseFile(t, leaseDir, group)
	if !bytes.Equal(fresh.GetLeaseId(), otherLeaseID) || len(fresh.GetSlots()) != 1 || !bytes.Equal(fresh.GetSlots()[0].GetExecutionId(), otherSlotID) {
		t.Fatalf("replacement lease id %x slots %d", fresh.GetLeaseId(), len(fresh.GetSlots()))
	}
	if fresh.GetLeaseVersion() != edgerecord.SweepLeaseCheckSetsVersion {
		t.Fatalf("replacement lease_version = %d, want 2", fresh.GetLeaseVersion())
	}
	t.Logf("a different lease id replaced the installed lease outright")
	stopPlanLeaseAgent(cmd)
}

func startPlanLeaseAgent(t *testing.T, ctx context.Context, binary, root, gateway string, logs *agentOutput) *exec.Cmd {
	t.Helper()
	checkers := filepath.Join(root, "checkers")
	if err := os.MkdirAll(checkers, 0o755); err != nil {
		t.Fatalf("checkers dir: %v", err)
	}
	configPath := filepath.Join(root, "agent.json")
	config := fmt.Sprintf(`{
		"agent_id": "plan-lease-live",
		"checkers_dir": %q,
		"partition": "default",
		"gateway_addr": %q,
		"push_interval": "1h",
		"gateway_security": {"mode": "none"},
		"logging": {"level": "info", "output": "stdout"}
	}`, checkers, gateway)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	cmd := exec.CommandContext(ctx, binary, "--config", configPath)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "SR_ALLOW_INSECURE=true", "SERVICERADAR_AGENT_RUNTIME_ROOT="+root)
	cmd.Stdout = logs
	cmd.Stderr = logs
	if err := cmd.Start(); err != nil {
		t.Fatalf("start agent: %v\nlog:\n%s", err, logs.snapshot())
	}
	t.Cleanup(func() { stopPlanLeaseAgent(cmd) })
	return cmd
}

func stopPlanLeaseAgent(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
}

type planLeaseOp struct {
	chunks []*proto.SweepLeaseChunk
	result chan planLeaseResult
}

type planLeaseResult struct {
	ack *proto.SweepLeaseAck
	err error
}

type planLeaseGateway struct {
	proto.UnimplementedAgentGatewayServiceServer
	mu     sync.Mutex
	enroll []string
	hellos chan []string
	ops    chan planLeaseOp
	ended  chan struct{}
}

func newPlanLeaseGateway() *planLeaseGateway {
	return &planLeaseGateway{
		hellos: make(chan []string, 4),
		ops:    make(chan planLeaseOp),
		ended:  make(chan struct{}, 4),
	}
}

func (g *planLeaseGateway) Hello(_ context.Context, req *proto.AgentHelloRequest) (*proto.AgentHelloResponse, error) {
	g.mu.Lock()
	g.enroll = append([]string(nil), req.GetCapabilities()...)
	g.mu.Unlock()
	return &proto.AgentHelloResponse{
		Accepted:             true,
		AgentId:              req.GetAgentId(),
		GatewayId:            "disposable-gateway",
		HeartbeatIntervalSec: 30,
	}, nil
}

func (g *planLeaseGateway) GetConfig(context.Context, *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	return &proto.AgentConfigResponse{NotModified: true}, nil
}

func (g *planLeaseGateway) PushStatus(context.Context, *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func (g *planLeaseGateway) ControlStream(stream grpc.BidiStreamingServer[proto.ControlStreamRequest, proto.ControlStreamResponse]) error {
	defer func() { g.ended <- struct{}{} }()

	incoming := make(chan *proto.ControlStreamRequest, 16)
	readErr := make(chan error, 1)
	go func() {
		for {
			msg, err := stream.Recv()
			if err != nil {
				readErr <- err
				return
			}
			incoming <- msg
		}
	}()

	for {
		select {
		case err := <-readErr:
			return err
		case msg := <-incoming:
			hello := msg.GetHello()
			if hello == nil {
				continue
			}
			g.hellos <- append([]string(nil), hello.GetCapabilities()...)
			return g.serveLeasePushes(stream, incoming, readErr)
		}
	}
}

func (g *planLeaseGateway) serveLeasePushes(
	stream grpc.BidiStreamingServer[proto.ControlStreamRequest, proto.ControlStreamResponse],
	incoming <-chan *proto.ControlStreamRequest,
	readErr <-chan error,
) error {
	for {
		select {
		case err := <-readErr:
			return err
		case msg := <-incoming:
			// A hello can be followed by a release report. Leave lease acks for a push.
			_ = msg
		case op := <-g.ops:
			if err := sendLeaseChunks(stream, op.chunks); err != nil {
				op.result <- planLeaseResult{err: err}
				return err
			}
			ack, err := waitLeaseAck(incoming, readErr)
			op.result <- planLeaseResult{ack: ack, err: err}
			if err != nil {
				return err
			}
		}
	}
}

func sendLeaseChunks(stream grpc.BidiStreamingServer[proto.ControlStreamRequest, proto.ControlStreamResponse], chunks []*proto.SweepLeaseChunk) error {
	for _, chunk := range chunks {
		if err := stream.Send(&proto.ControlStreamResponse{
			Payload: &proto.ControlStreamResponse_SweepLeaseChunk{SweepLeaseChunk: chunk},
		}); err != nil {
			return err
		}
	}
	return nil
}

func waitLeaseAck(incoming <-chan *proto.ControlStreamRequest, readErr <-chan error) (*proto.SweepLeaseAck, error) {
	for {
		select {
		case err := <-readErr:
			return nil, err
		case msg := <-incoming:
			if ack := msg.GetSweepLeaseAck(); ack != nil {
				return ack, nil
			}
		}
	}
}

func (g *planLeaseGateway) waitHello(t *testing.T, logs *agentOutput) []string {
	t.Helper()
	select {
	case hello := <-g.hellos:
		return hello
	case <-time.After(45 * time.Second):
		t.Fatalf("agent did not open a control stream\nlog:\n%s", logs.snapshot())
	}
	return nil
}

func (g *planLeaseGateway) waitStreamEnd(t *testing.T, logs *agentOutput) {
	t.Helper()
	select {
	case <-g.ended:
	case <-time.After(15 * time.Second):
		t.Fatalf("control stream did not end after the agent stopped\nlog:\n%s", logs.snapshot())
	}
}

func (g *planLeaseGateway) push(t *testing.T, logs *agentOutput, group string, lease *edgev1.SweepLeaseV1) *proto.SweepLeaseAck {
	t.Helper()
	op := planLeaseOp{chunks: planLeaseChunks(t, group, lease), result: make(chan planLeaseResult, 1)}
	select {
	case g.ops <- op:
	case <-time.After(5 * time.Second):
		t.Fatalf("control stream is not receiving a push\nlog:\n%s", logs.snapshot())
	}
	select {
	case result := <-op.result:
		if result.err != nil {
			t.Fatalf("lease push: %v\nlog:\n%s", result.err, logs.snapshot())
		}
		return result.ack
	case <-time.After(20 * time.Second):
		t.Fatalf("no sweep lease ack\nlog:\n%s", logs.snapshot())
	}
	return nil
}

func requireCapabilities(t *testing.T, got []string, want ...string) {
	t.Helper()
	have := map[string]bool{}
	for _, cap := range got {
		have[cap] = true
	}
	for _, cap := range want {
		if !have[cap] {
			t.Fatalf("control hello missing %s in %v", cap, got)
		}
	}
}

func planLeaseChunks(t *testing.T, group string, lease *edgev1.SweepLeaseV1) []*proto.SweepLeaseChunk {
	t.Helper()
	payload, err := goproto.Marshal(lease)
	if err != nil {
		t.Fatalf("marshal lease: %v", err)
	}
	sum := sha256.Sum256(payload)
	digest := hex.EncodeToString(sum[:])
	mid := len(payload) / 2
	if mid == 0 {
		mid = len(payload)
	}
	parts := [][]byte{payload[:mid]}
	if mid < len(payload) {
		parts = append(parts, payload[mid:])
	}
	chunks := make([]*proto.SweepLeaseChunk, 0, len(parts))
	for i, part := range parts {
		chunks = append(chunks, &proto.SweepLeaseChunk{
			SweepGroupId:  group,
			Payload:       part,
			ChunkIndex:    int32(i),
			TotalChunks:   int32(len(parts)),
			IsFinal:       i == len(parts)-1,
			PayloadSha256: digest,
		})
	}
	return chunks
}

func carriedLease(group string, leaseID, assignment, execution []byte, slotAt time.Time) *edgev1.SweepLeaseV1 {
	checks := []*edgev1.SweepTestV1{{
		Mode:     edgev1.SweepMode_SWEEP_MODE_ICMP,
		Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
	}}
	start := slotAt.UnixNano()
	return &edgev1.SweepLeaseV1{
		LeaseVersion:         edgerecord.SweepLeaseCheckSetsVersion,
		SweepGroupId:         uuidBytes(group),
		LeaseId:              leaseID,
		ProducerAssignmentId: assignment,
		AuthorityEpoch:       1,
		ProductionCapability: &edgev1.EdgeSignedCapabilityV1{},
		WindowStartUnixNano:  start - int64(time.Second),
		WindowEndUnixNano:    start + int64(time.Second),
		CheckSets: []*edgev1.SweepCheckSetV1{{
			CheckSetSha256: edgerecord.CheckSetDigest(checks),
			DigestVersion:  edgerecord.CheckSetDigestVersion,
			Checks:         checks,
		}},
		Slots: []*edgev1.SweepLeaseSlotV1{{
			ExecutionId:               execution,
			SlotStartUnixNano:         start,
			CollectionExpiresUnixNano: start + int64(15*time.Minute),
			PlanHeader:                &edgev1.ScheduledPlanHeaderV1{CheckSetSha256: edgerecord.CheckSetDigest(checks)},
		}},
	}
}

func slotlessLease(group string, leaseID []byte, windowAt time.Time) *edgev1.SweepLeaseV1 {
	start := windowAt.UnixNano()
	return &edgev1.SweepLeaseV1{
		LeaseVersion:         1,
		SweepGroupId:         uuidBytes(group),
		LeaseId:              leaseID,
		ProducerAssignmentId: fixedID("aaaaaaaabbbb4ccc"),
		AuthorityEpoch:       1,
		WindowStartUnixNano:  start,
		WindowEndUnixNano:    start + int64(time.Minute),
	}
}

func prePlanSlotLease(group string) *edgev1.SweepLeaseV1 {
	lease := slotlessLease(group, fixedID("4444444455554666"), time.Unix(100, 0))
	lease.Slots = []*edgev1.SweepLeaseSlotV1{{
		ExecutionId:               fixedID("5555555566664777"),
		SlotStartUnixNano:         lease.GetWindowStartUnixNano(),
		CollectionExpiresUnixNano: lease.GetWindowEndUnixNano(),
	}}
	return lease
}

func writeLeaseFile(t *testing.T, dir, group string, lease *edgev1.SweepLeaseV1) {
	t.Helper()
	data, err := goproto.Marshal(lease)
	if err != nil {
		t.Fatalf("marshal %s: %v", group, err)
	}
	if err := os.WriteFile(filepath.Join(dir, group+".pb"), data, 0o600); err != nil {
		t.Fatalf("write %s: %v", group, err)
	}
}

func readLeaseFile(t *testing.T, dir, group string) *edgev1.SweepLeaseV1 {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, group+".pb"))
	if err != nil {
		t.Fatalf("read %s: %v", group, err)
	}
	lease := &edgev1.SweepLeaseV1{}
	if err := goproto.Unmarshal(data, lease); err != nil {
		t.Fatalf("decode %s: %v", group, err)
	}
	return lease
}

func fixedID(prefix string) []byte {
	id := make([]byte, 16)
	raw := uuidBytes(prefix)
	copy(id, raw)
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

func uuidBytes(dashed string) []byte {
	raw := strings.ReplaceAll(dashed, "-", "")
	if len(raw) > 32 {
		raw = raw[:32]
	}
	for len(raw) < 32 {
		raw += "0"
	}
	buf, err := hex.DecodeString(raw)
	if err != nil {
		panic(err)
	}
	return buf
}
