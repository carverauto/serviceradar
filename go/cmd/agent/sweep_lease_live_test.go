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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
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

	root, leaseDir := preparePlanLeaseDir(t)
	staleGroup := "22222222-3333-4444-8555-666666666666"
	heldGroup := "33333333-4444-4555-8666-777777777777"
	seedStoredPlanLeases(t, leaseDir, staleGroup, heldGroup)

	gw, gatewayAddr := servePlanLeaseGateway(t, ctx)
	group := "11111111-2222-3333-4444-555555555555"
	leaseID := fixedID("6666666677774888")
	otherLeaseID := fixedID("7777777788884999")
	assignment := fixedID("aaaaaaaabbbb4ccc")
	slotID := fixedID("1212121234344565")
	otherSlotID := fixedID("1313131335354575")
	now := time.Now()
	slotAt := now.Add(time.Hour)

	logs := &agentOutput{}
	cmd := startPlanLeaseAgent(t, ctx, binary, root, gatewayAddr, logs)
	assertStartupKeepsOnlySlotlessLease(t, gw, logs, leaseDir, staleGroup, heldGroup)
	onDisk := assertCarriedLeaseInstalls(t, gw, logs, leaseDir, group, leaseID, assignment, slotID, slotAt)
	assertUnknownDigestRefusesPush(t, gw, logs, leaseDir, group, leaseID, assignment, slotID, slotAt, onDisk)
	assertSlotlessPushKeepsCarriedSlot(t, gw, logs, leaseDir, group, leaseID, slotID, now)

	stopPlanLeaseAgent(cmd)
	gw.waitStreamEnd(t, logs)
	logs = &agentOutput{}
	cmd = startPlanLeaseAgent(t, ctx, binary, root, gatewayAddr, logs)
	assertReloadedLeaseKeepsCarriedSlot(t, gw, logs, leaseDir, group, leaseID, slotID, now)
	assertDifferentLeaseReplacesInstalled(t, gw, logs, leaseDir, group, otherLeaseID, assignment, otherSlotID, slotAt)
	stopPlanLeaseAgent(cmd)
}

func preparePlanLeaseDir(t *testing.T) (root, leaseDir string) {
	t.Helper()
	root = t.TempDir()
	leaseDir = filepath.Join(root, "sweep-leases")
	if err := os.MkdirAll(leaseDir, 0o755); err != nil {
		t.Fatalf("lease dir: %v", err)
	}
	return root, leaseDir
}

func seedStoredPlanLeases(t *testing.T, leaseDir, staleGroup, heldGroup string) {
	t.Helper()
	writeLeaseFile(t, leaseDir, staleGroup, prePlanSlotLease(staleGroup))
	if err := os.WriteFile(filepath.Join(leaseDir, staleGroup+".executed.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatalf("stale sidecar: %v", err)
	}
	writeLeaseFile(t, leaseDir, heldGroup, slotlessLease(heldGroup, fixedID("aaaaaaaaaaaabbbb"), time.Now()))
}

func servePlanLeaseGateway(t *testing.T, ctx context.Context) (*planLeaseGateway, string) {
	t.Helper()
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
	return gw, lis.Addr().String()
}

func assertStartupKeepsOnlySlotlessLease(t *testing.T, gw *planLeaseGateway, logs *agentOutput, leaseDir, staleGroup, heldGroup string) {
	t.Helper()
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
}

func assertCarriedLeaseInstalls(t *testing.T, gw *planLeaseGateway, logs *agentOutput, leaseDir, group string, leaseID, assignment, slotID []byte, slotAt time.Time) *edgev1.SweepLeaseV1 {
	t.Helper()
	installed := gw.push(t, logs, carriedLease(group, leaseID, assignment, slotID, slotAt))
	if !installed.GetInstalled() || installed.GetInstalledSlotCount() != 1 || installed.GetError() != "" {
		t.Fatalf("v2 install ack = installed:%t slots:%d err:%q", installed.GetInstalled(), installed.GetInstalledSlotCount(), installed.GetError())
	}
	onDisk := readLeaseFile(t, leaseDir, group)
	if onDisk.GetLeaseVersion() != edgerecord.SweepLeaseCheckSetsVersion || !bytes.Equal(onDisk.GetSlots()[0].GetExecutionId(), slotID) {
		t.Fatalf("installed lease = version %d execution %x", onDisk.GetLeaseVersion(), onDisk.GetSlots()[0].GetExecutionId())
	}
	t.Logf("v2 push installed lease_version %d with the carried slot", onDisk.GetLeaseVersion())
	return onDisk
}

func assertUnknownDigestRefusesPush(t *testing.T, gw *planLeaseGateway, logs *agentOutput, leaseDir, group string, leaseID, assignment, slotID []byte, slotAt time.Time, installed *edgev1.SweepLeaseV1) {
	t.Helper()
	broken := carriedLease(group, leaseID, assignment, slotID, slotAt)
	broken.CheckSets[0].DigestVersion = 2
	refused := gw.push(t, logs, broken)
	if refused.GetInstalled() || !strings.Contains(refused.GetError(), "digest_version") {
		t.Fatalf("unknown digest ack = installed:%t err:%q", refused.GetInstalled(), refused.GetError())
	}
	afterRefusal := readLeaseFile(t, leaseDir, group)
	if !goproto.Equal(installed, afterRefusal) {
		t.Fatalf("refused push changed the installed lease")
	}
	t.Logf("unknown digest_version refused the push and left the installed lease in place: %s", refused.GetError())
}

func assertSlotlessPushKeepsCarriedSlot(t *testing.T, gw *planLeaseGateway, logs *agentOutput, leaseDir, group string, leaseID, slotID []byte, now time.Time) {
	t.Helper()
	kept := gw.push(t, logs, slotlessLease(group, leaseID, now))
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
}

func assertReloadedLeaseKeepsCarriedSlot(t *testing.T, gw *planLeaseGateway, logs *agentOutput, leaseDir, group string, leaseID, slotID []byte, now time.Time) {
	t.Helper()
	reloadedHello := gw.waitHello(t, logs)
	requireCapabilities(t, reloadedHello, "sweep_lease_v1", "sweep_lease_plan_checks:v1")
	reloaded := gw.push(t, logs, slotlessLease(group, leaseID, now))
	if !reloaded.GetInstalled() || reloaded.GetInstalledSlotCount() != 1 {
		t.Fatalf("reload ack = installed:%t slots:%d err:%q", reloaded.GetInstalled(), reloaded.GetInstalledSlotCount(), reloaded.GetError())
	}
	survived := readLeaseFile(t, leaseDir, group)
	if survived.GetLeaseVersion() != edgerecord.SweepLeaseCheckSetsVersion || !bytes.Equal(survived.GetSlots()[0].GetExecutionId(), slotID) {
		t.Fatalf("reloaded lease = version %d execution %x", survived.GetLeaseVersion(), survived.GetSlots()[0].GetExecutionId())
	}
	t.Logf("after restart a same-lease slot-less push still resolved the carried slot at lease_version 2")
}

func assertDifferentLeaseReplacesInstalled(t *testing.T, gw *planLeaseGateway, logs *agentOutput, leaseDir, group string, otherLeaseID, assignment, otherSlotID []byte, slotAt time.Time) {
	t.Helper()
	replaced := gw.push(t, logs, carriedLease(group, otherLeaseID, assignment, otherSlotID, slotAt.Add(time.Hour)))
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

func (g *planLeaseGateway) push(t *testing.T, logs *agentOutput, lease *edgev1.SweepLeaseV1) *proto.SweepLeaseAck {
	t.Helper()
	op := planLeaseOp{chunks: planLeaseChunks(t, dashedUUID(lease.GetSweepGroupId()), lease), result: make(chan planLeaseResult, 1)}
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

// A running agent, given a group whose own config is ICMP on a documentation
// address, runs a leased slot's TCP connect against the plan's address and
// stays off that group's interval ticker across a restart.
func TestRunningAgentRunsPlanTCPConnectWhileTheGroupTickerStaysOff(t *testing.T) {
	binary := agentTestBinary(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() {
		if err := listener.Close(); err != nil {
			t.Errorf("close listener: %v", err)
		}
	})
	go func() {
		for {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	port := listener.Addr().(*net.TCPAddr).Port

	root := t.TempDir()
	spoolDir := filepath.Join(root, "spool")
	groupBytes, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("group id: %v", err)
	}
	group := dashedUUID(groupBytes)
	slotAt := time.Now().Add(4 * time.Second)
	leaseID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("lease id: %v", err)
	}
	assignment, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("assignment id: %v", err)
	}
	lease := executablePlanLease(t, groupBytes, leaseID, assignment, "127.0.0.1/32", 1, []*edgev1.SweepTestV1{{
		Mode:     edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT,
		Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
		Port:     uint32(port),
	}}, slotAt, slotAt.Add(45*time.Second))

	gw := newExecLeaseGateway()
	lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("gateway listen: %v", err)
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(server.Stop)

	logs := &agentOutput{}
	cmd := startSweepExecAgent(t, ctx, binary, root, spoolDir, lis.Addr().String(), logs)
	hello := gw.waitHello(t, logs)
	requireCapabilities(t, hello, "sweep_lease_v1", "sweep_lease_plan_checks:v1")

	installed := gw.pushLease(t, logs, group, lease)
	if !installed.GetInstalled() || installed.GetInstalledSlotCount() != 1 || installed.GetError() != "" {
		t.Fatalf("plan install ack = installed:%t slots:%d err:%q\nlog:\n%s", installed.GetInstalled(), installed.GetInstalledSlotCount(), installed.GetError(), logs.snapshot())
	}
	gw.pushConfig(t, logs, icmpGroupConfig(group))
	waitForLog(t, logs, "Applied sweep group config from gateway", 15*time.Second)
	waitForLog(t, logs, "Manual schedule active, skipping initial sweep", 15*time.Second)
	time.Sleep(3 * time.Second)
	logText := string(logs.snapshot())
	if strings.Contains(logText, "Initial sweep completed successfully") || strings.Contains(logText, "Ticker fired, starting periodic sweep") {
		t.Fatalf("leased group ran its local ticker:\n%s", logText)
	}
	t.Logf("group config is ICMP on a 1s interval; the leased group skipped its initial sweep and did not tick")

	waitForLog(t, logs, "Ran leased sweep slot", 30*time.Second)
	stopPlanLeaseAgent(cmd)
	gw.waitStreamEnd(t, logs)

	batch := readSweepBatch(t, spoolDir)
	if batch.GetConfiguredModeBits() != uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT) {
		t.Fatalf("spooled mode bits = %d, want tcp connect only", batch.GetConfiguredModeBits())
	}
	if len(batch.GetTestedChecks()) != 1 || batch.GetTestedChecks()[0].GetMode() != edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT || batch.GetTestedChecks()[0].GetPort() != uint32(port) {
		t.Fatalf("spooled checks = %v", batch.GetTestedChecks())
	}
	if len(batch.GetHosts()) != 1 || !bytes.Equal(batch.GetHosts()[0].GetAddress(), net.ParseIP("127.0.0.1").To4()) {
		t.Fatalf("spooled hosts = %v", batch.GetHosts())
	}
	if batch.GetHosts()[0].GetTcp().GetOpenCount() != 1 {
		t.Fatalf("tcp connect did not reach the listener: %+v", batch.GetHosts()[0].GetTcp())
	}
	t.Logf("planned TCP connect to 127.0.0.1:%d opened; the ICMP group config contributed no mode", port)

	logs = &agentOutput{}
	cmd = startSweepExecAgent(t, ctx, binary, root, spoolDir, lis.Addr().String(), logs)
	_ = gw.waitHello(t, logs)
	gw.pushConfig(t, logs, icmpGroupConfig(group))
	waitForLog(t, logs, "Manual schedule active, skipping initial sweep", 15*time.Second)
	time.Sleep(3 * time.Second)
	reloaded := string(logs.snapshot())
	if strings.Contains(reloaded, "Initial sweep completed successfully") || strings.Contains(reloaded, "Ticker fired, starting periodic sweep") {
		t.Fatalf("reloaded lease let the group tick:\n%s", reloaded)
	}
	if strings.Contains(reloaded, "Ran leased sweep slot") {
		t.Fatalf("reloaded agent ran the slot again:\n%s", reloaded)
	}
	t.Logf("after restart the started slot stayed executed and the group stayed off its ticker")
	stopPlanLeaseAgent(cmd)
}

// A running agent judges an IPv6 TCP SYN slot from the scanner the planned run
// creates. When that scanner cannot send raw IPv6 SYN, one refusal names every
// missing marker, a hello carries a new marker before the refusal, and the
// refusal is sent again on the next control stream until 24 hours past the
// slot's collection expiry.
func TestRunningAgentRefusesUnavailablePlannedModesBeforeClaim(t *testing.T) {
	binary := agentTestBinary(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	root := t.TempDir()
	spoolDir := filepath.Join(root, "spool")
	group, lease, collection := unavailableICMPAndTCPSYNLease(t)
	gw, gatewayAddr := serveExecLeaseGateway(t, ctx)

	logs := &agentOutput{}
	cmd := startSweepExecAgent(t, ctx, binary, root, spoolDir, gatewayAddr, logs)
	icmpMissing := assertNoIPv6MarkerBeforeSlot(t, gw, logs)
	assertUnavailablePlanInstalled(t, gw, logs, group, lease)
	refusal := assertOneRefusalBeforeClaim(t, gw, logs, lease, icmpMissing)
	assertRefusalRetainedForLookback(t, root, spoolDir, group, lease, collection)
	assertRefusalResentOnReconnect(t, gw, logs, refusal)
	stopPlanLeaseAgent(cmd)
	gw.waitStreamEnd(t, logs)

	// The reader drops a refusal once its stored retain timestamp is reached.
	// Moving that timestamp is the clock reaching the bound the writer stored.
	assertRefusalHeldWhileTimestampAhead(t, ctx, binary, root, spoolDir, gatewayAddr, gw, group, lease, refusal)
	assertRefusalDroppedWhenTimestampPassed(t, ctx, binary, root, spoolDir, gatewayAddr, gw, group, lease)
}

func unavailableICMPAndTCPSYNLease(t *testing.T) (group string, lease *edgev1.SweepLeaseV1, collection time.Time) {
	t.Helper()
	groupBytes, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("group id: %v", err)
	}
	group = dashedUUID(groupBytes)
	leaseID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("lease id: %v", err)
	}
	assignment, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("assignment id: %v", err)
	}
	slotAt := time.Now().Add(4 * time.Second)
	collection = slotAt.Add(2 * time.Minute)
	lease = executablePlanLease(t, groupBytes, leaseID, assignment, "2001:db8::1/128", 1, []*edgev1.SweepTestV1{
		{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_SYN, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
	}, slotAt, collection)
	return group, lease, collection
}

func serveExecLeaseGateway(t *testing.T, ctx context.Context) (*execLeaseGateway, string) {
	t.Helper()
	gw := newExecLeaseGateway()
	lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("gateway listen: %v", err)
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(server.Stop)
	return gw, lis.Addr().String()
}

func assertNoIPv6MarkerBeforeSlot(t *testing.T, gw *execLeaseGateway, logs *agentOutput) bool {
	t.Helper()
	hello := gw.waitHello(t, logs)
	icmpMissing := containsCap(hello, "icmp.unavailable")
	if containsCap(hello, "tcp_syn_ipv6.unavailable") {
		t.Fatalf("hello already carries tcp_syn_ipv6.unavailable before any slot: %v", hello)
	}
	t.Logf("startup hello icmp.unavailable=%t", icmpMissing)
	return icmpMissing
}

func assertUnavailablePlanInstalled(t *testing.T, gw *execLeaseGateway, logs *agentOutput, group string, lease *edgev1.SweepLeaseV1) {
	t.Helper()
	installed := gw.pushLease(t, logs, group, lease)
	if !installed.GetInstalled() || installed.GetError() != "" {
		t.Fatalf("install ack = installed:%t err:%q\nlog:\n%s", installed.GetInstalled(), installed.GetError(), logs.snapshot())
	}
	gw.pushConfig(t, logs, icmpGroupConfig(group))
	waitForLog(t, logs, "Applied sweep group config from gateway", 15*time.Second)
}

func assertOneRefusalBeforeClaim(t *testing.T, gw *execLeaseGateway, logs *agentOutput, lease *edgev1.SweepLeaseV1, icmpMissing bool) *proto.SweepLeaseSlotRefusal {
	t.Helper()
	refusal := gw.waitRefusal(t, logs, 30*time.Second)
	wantMarkers := []string{"tcp_syn_ipv6.unavailable"}
	if icmpMissing {
		wantMarkers = []string{"icmp.unavailable", "tcp_syn_ipv6.unavailable"}
	}
	if refusal.GetReason() != proto.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE {
		t.Fatalf("refusal reason = %s", refusal.GetReason())
	}
	if strings.Join(refusal.GetUnavailableCapabilities(), ",") != strings.Join(wantMarkers, ",") {
		t.Fatalf("refusal markers = %v, want %v (detail %s)", refusal.GetUnavailableCapabilities(), wantMarkers, refusal.GetDetail())
	}
	if !bytes.Equal(refusal.GetExecutionId(), lease.GetSlots()[0].GetExecutionId()) {
		t.Fatalf("refusal execution = %x", refusal.GetExecutionId())
	}
	helloAt, refusalAt := refusalFollowsMarkerHello(gw.snapshot())
	if helloAt < 0 || refusalAt < 0 || helloAt > refusalAt {
		t.Fatalf("marker hello index %d, refusal index %d", helloAt, refusalAt)
	}
	if strings.Contains(string(logs.snapshot()), "Ran leased sweep slot") {
		t.Fatalf("refused slot still ran:\n%s", logs.snapshot())
	}
	t.Logf("one refusal before the slot ran, markers %v, detail %s; hello with the new marker preceded it", refusal.GetUnavailableCapabilities(), refusal.GetDetail())
	return refusal
}

func refusalFollowsMarkerHello(messages []*proto.ControlStreamRequest) (helloAt, refusalAt int) {
	helloAt = -1
	refusalAt = -1
	for i, msg := range messages {
		if h := msg.GetHello(); h != nil && containsCap(h.GetCapabilities(), "tcp_syn_ipv6.unavailable") && helloAt < 0 {
			helloAt = i
		}
		if msg.GetSweepLeaseSlotRefusal() != nil && refusalAt < 0 {
			refusalAt = i
		}
	}
	return helloAt, refusalAt
}

func assertRefusalRetainedForLookback(t *testing.T, root, spoolDir, group string, lease *edgev1.SweepLeaseV1, collection time.Time) {
	t.Helper()
	// Decision 12 / LeaseMisses lookback: keep the refusal until 24 hours past
	// collection expiry. The bound is that lookback, written here, not a
	// constant read back from the agent.
	const leaseMissLookback = 24 * time.Hour
	stored := readRefusalFile(t, filepath.Join(root, "sweep-leases", group+".refusals.json"))
	executionKey := dashedUUID(lease.GetSlots()[0].GetExecutionId())
	record, ok := stored[executionKey]
	if !ok {
		t.Fatalf("refusal file keys = %v, want %s", refusalKeys(stored), executionKey)
	}
	wantRetain := collection.UnixNano() + int64(leaseMissLookback)
	if record.RetainUntilUnixNano != wantRetain {
		t.Fatalf("retain_until = %d, want collection expiry + 24h (%d)", record.RetainUntilUnixNano, wantRetain)
	}
	t.Logf("persisted retain_until is the slot collection expiry plus 24h")
	assertSpoolHasNoRecords(t, spoolDir)
}

func assertSpoolHasNoRecords(t *testing.T, spoolDir string) {
	t.Helper()
	sp, err := spool.Open(spoolDir)
	if err != nil {
		t.Fatalf("open spool: %v", err)
	}
	records, err := sp.Unresolved()
	closeErr := sp.Close()
	if err != nil {
		t.Fatalf("spool unresolved: %v", err)
	}
	if closeErr != nil {
		t.Fatalf("close spool: %v", closeErr)
	}
	if len(records) != 0 {
		t.Fatalf("refused slot wrote %d spool records", len(records))
	}
}

func assertRefusalResentOnReconnect(t *testing.T, gw *execLeaseGateway, logs *agentOutput, refusal *proto.SweepLeaseSlotRefusal) {
	t.Helper()
	gw.disconnect()
	gw.waitStreamEnd(t, logs)
	rehello := gw.waitHello(t, logs)
	if !containsCap(rehello, "tcp_syn_ipv6.unavailable") {
		t.Fatalf("reconnect hello = %v", rehello)
	}
	resent := gw.waitRefusal(t, logs, 20*time.Second)
	if !goproto.Equal(refusal, resent) {
		t.Fatalf("resent refusal = %+v", resent)
	}
	t.Logf("the next control stream carried the marker and the same refusal")
}

func assertRefusalHeldWhileTimestampAhead(t *testing.T, ctx context.Context, binary, root, spoolDir, gateway string, gw *execLeaseGateway, group string, lease *edgev1.SweepLeaseV1, refusal *proto.SweepLeaseSlotRefusal) {
	t.Helper()
	rewriteRefusalRetain(t, root, group, lease, time.Now().Add(30*time.Second).UnixNano())
	logs := &agentOutput{}
	cmd := startSweepExecAgent(t, ctx, binary, root, spoolDir, gateway, logs)
	_ = gw.waitHello(t, logs)
	stillHeld := gw.waitRefusal(t, logs, 15*time.Second)
	if !bytes.Equal(stillHeld.GetExecutionId(), refusal.GetExecutionId()) {
		t.Fatalf("held refusal execution = %x", stillHeld.GetExecutionId())
	}
	t.Logf("a refusal whose retain timestamp is still ahead is sent on connect")
	stopPlanLeaseAgent(cmd)
	gw.waitStreamEnd(t, logs)
}

func assertRefusalDroppedWhenTimestampPassed(t *testing.T, ctx context.Context, binary, root, spoolDir, gateway string, gw *execLeaseGateway, group string, lease *edgev1.SweepLeaseV1) {
	t.Helper()
	rewriteRefusalRetain(t, root, group, lease, time.Now().Add(-time.Nanosecond).UnixNano())
	logs := &agentOutput{}
	cmd := startSweepExecAgent(t, ctx, binary, root, spoolDir, gateway, logs)
	defer stopPlanLeaseAgent(cmd)
	_ = gw.waitHello(t, logs)
	select {
	case late := <-gw.refusals:
		t.Fatalf("refusal was sent after its retain timestamp: %+v", late)
	case <-time.After(6 * time.Second):
		t.Logf("a refusal whose retain timestamp has passed is not sent")
	}
}

func rewriteRefusalRetain(t *testing.T, root, group string, lease *edgev1.SweepLeaseV1, retainUntil int64) {
	t.Helper()
	path := filepath.Join(root, "sweep-leases", group+".refusals.json")
	stored := readRefusalFile(t, path)
	executionKey := dashedUUID(lease.GetSlots()[0].GetExecutionId())
	record, ok := stored[executionKey]
	if !ok {
		t.Fatalf("refusal file keys = %v, want %s", refusalKeys(stored), executionKey)
	}
	record.RetainUntilUnixNano = retainUntil
	stored[executionKey] = record
	writeRefusalFile(t, path, stored)
}

func startSweepExecAgent(t *testing.T, ctx context.Context, binary, root, spoolDir, gateway string, logs *agentOutput) *exec.Cmd {
	t.Helper()
	checkers := filepath.Join(root, "checkers")
	if err := os.MkdirAll(checkers, 0o755); err != nil {
		t.Fatalf("checkers dir: %v", err)
	}
	configPath := filepath.Join(root, "agent.json")
	config := fmt.Sprintf(`{
		"agent_id": "plan-lease-exec",
		"checkers_dir": %q,
		"partition": "default",
		"gateway_addr": %q,
		"push_interval": "1h",
		"gateway_security": {"mode": "none"},
		"logging": {"level": "debug", "output": "stdout"},
		"edge_record_sender": {
			"enabled": true,
			"sweep_enabled": true,
			"max_bytes": %d,
			"spool_dir": %q,
			"poll_interval": "1h"
		}
	}`, checkers, gateway, 32<<20, spoolDir)
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

func icmpGroupConfig(group string) *proto.AgentConfigResponse {
	body := fmt.Sprintf(`{"sweep":{"config_hash":"live-icmp","groups":[{
		"id": %q,
		"sweep_group_id": %q,
		"targets": ["192.0.2.1/32"],
		"modes": ["icmp"],
		"schedule": {"type": "interval", "interval": "1s"},
		"settings": {"concurrency": 4, "timeout": "2s", "scan_timeout": "15s"}
	}]}}`, group, group)
	return &proto.AgentConfigResponse{
		ConfigVersion:   "live-icmp-" + group,
		ConfigTimestamp: time.Now().Unix(),
		ConfigJson:      []byte(body),
	}
}

func waitForLog(t *testing.T, logs *agentOutput, needle string, budget time.Duration) {
	t.Helper()
	deadline := time.Now().Add(budget)
	for time.Now().Before(deadline) {
		if strings.Contains(string(logs.snapshot()), needle) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("log never contained %q\nlog:\n%s", needle, logs.snapshot())
}

func readSweepBatch(t *testing.T, spoolDir string) *edgev1.SweepObservationBatchV1 {
	t.Helper()
	sp, err := spool.Open(spoolDir)
	if err != nil {
		t.Fatalf("open spool: %v", err)
	}
	t.Cleanup(func() {
		if err := sp.Close(); err != nil {
			t.Errorf("close spool: %v", err)
		}
	})
	records, err := sp.Unresolved()
	if err != nil {
		t.Fatalf("spool unresolved: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("spool records = %d, want 1", len(records))
	}
	record := &edgev1.EdgeRecordV1{}
	if err := goproto.Unmarshal(records[0].Body, record); err != nil {
		t.Fatalf("decode record: %v", err)
	}
	payload := record.GetPayload()
	if record.GetCompression() == edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD {
		payload, err = edgerecord.DecompressZstdPayload(payload, record.GetUncompressedSize())
		if err != nil {
			t.Fatalf("decompress record: %v", err)
		}
	}
	batch := &edgev1.SweepObservationBatchV1{}
	if err := goproto.Unmarshal(payload, batch); err != nil {
		t.Fatalf("decode batch: %v", err)
	}
	return batch
}

type storedRefusal struct {
	RetainUntilUnixNano int64  `json:"retain_until_unix_nano"`
	Refusal             []byte `json:"refusal"`
}

func readRefusalFile(t *testing.T, path string) map[string]storedRefusal {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read refusals: %v", err)
	}
	var stored map[string]storedRefusal
	if err := json.Unmarshal(data, &stored); err != nil {
		t.Fatalf("decode refusals: %v", err)
	}
	return stored
}

func writeRefusalFile(t *testing.T, path string, stored map[string]storedRefusal) {
	t.Helper()
	data, err := json.Marshal(stored)
	if err != nil {
		t.Fatalf("encode refusals: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write refusals: %v", err)
	}
}

func refusalKeys(stored map[string]storedRefusal) []string {
	keys := make([]string, 0, len(stored))
	for key := range stored {
		keys = append(keys, key)
	}
	return keys
}

func containsCap(caps []string, want string) bool {
	for _, cap := range caps {
		if cap == want {
			return true
		}
	}
	return false
}

func dashedUUID(raw []byte) string {
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
}

// executablePlanLease is a lease the running agent can execute: signed plan,
// one range, and a production grant large enough for that range. The digests
// are the public plan grammar, so a lease that does not bind its range fails
// closed before a scan.
func executablePlanLease(t *testing.T, group, leaseID, assignment []byte, cidr string, targets uint64, checks []*edgev1.SweepTestV1, slotAt, collection time.Time) *edgev1.SweepLeaseV1 {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("issuer key: %v", err)
	}
	checkKey := edgerecord.CheckSetDigest(checks)
	rangeID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("range id: %v", err)
	}
	planID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("plan id: %v", err)
	}
	executionID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("execution id: %v", err)
	}
	networkScope, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("network scope: %v", err)
	}
	targetRange := &edgev1.TargetRangeV1{
		RangeId:              rangeID,
		Cidr:                 cidr,
		TargetCount:          targets,
		CheckSetSha256:       checkKey,
		AvailabilityPolicyId: []byte("any-success-v1"),
		MtrOrdinalCount:      goproto.Uint64(0),
	}
	targetRange.RangeSha256 = edgerecord.RangeDigest(targetRange)
	page := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: planID,
		PageIndex:       0,
		PageCount:       1,
		CheckSetSha256:  checkKey,
		DigestVersion:   edgerecord.PlanDigestVersion,
		Ranges:          []*edgev1.TargetRangeV1{targetRange},
	}
	page.PageSha256 = edgerecord.PlanPageDigest(page)
	pages := []*edgev1.ScheduledPlanPageV1{page}
	commitment, err := edgerecord.PlanMtrOrdinalRangeCommitment(pages)
	if err != nil {
		t.Fatalf("mtr commitment: %v", err)
	}
	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId:           planID,
		PageCount:                 1,
		TotalTargetCount:          targets,
		PlanRootSha256:            edgerecord.PlanRoot(pages),
		DigestVersion:             edgerecord.PlanDigestVersion,
		CheckSetSha256:            checkKey,
		AvailabilityPolicyId:      []byte("any-success-v1"),
		NetworkScopeId:            networkScope,
		MtrOrdinalRangeCommitment: commitment,
	}
	header.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(header)

	start := slotAt.UnixNano()
	expires := collection.UnixNano()
	sign := func(capability *edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeSignedCapabilityV1 {
		capability.CapabilityVersion = 1
		capability.IssuerId = []byte("live-issuer")
		capability.IssuerKeyId = []byte("live-issuer-key")
		capability.Algorithm = "ed25519"
		edgerecord.SignCapability(capability, key)
		return capability
	}
	digest := sha256.Sum256([]byte("live-sweep-contract"))
	source := sign(&edgev1.EdgeSignedCapabilityV1{
		NotBeforeUnixNano: start,
		ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{
			Kind:                        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
			ContextId:                   executionID,
			ScopeId:                     rangeID,
			ScopeSha256:                 targetRange.GetRangeSha256(),
			NetworkScopeId:              networkScope,
			CollectionNotBeforeUnixNano: start,
			CollectionExpiresUnixNano:   expires,
			ProducerAssignmentId:        assignment,
			RunId:                       leaseID,
			AuthorityEpoch:              1,
			ExecutionPlanSha256:         header.GetExecutionPlanSha256(),
			TargetRangeSha256:           targetRange.GetRangeSha256(),
			OriginKind:                  edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:           []byte("plan-lease-exec"),
			ProducerInstanceId:          []byte("plan-lease-exec"),
			RouteProfile:                edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:                edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		}},
	})
	issued := time.Now().Add(-time.Minute).UnixNano()
	production := sign(&edgev1.EdgeSignedCapabilityV1{
		NotBeforeUnixNano: issued,
		ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			NetworkScopeId:         networkScope,
			ProducerAssignmentId:   assignment,
			RunId:                  leaseID,
			AuthorityEpoch:         1,
			ScopeId:                group,
			ContractId:             "serviceradar.sweep.observation",
			ContractVersion:        1,
			ContractBundleSha256:   digest[:],
			RegistryEpoch:          1,
			RegistrySnapshotSha256: digest[:],
			EffectiveGrantSha256:   digest[:],
			OriginKind:             edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:      []byte("plan-lease-exec"),
			ProducerInstanceId:     []byte("plan-lease-exec"),
			PackageId:              "serviceradar.agent.sweep",
			PackageSha256:          digest[:],
			ScopeSha256:            digest[:],
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			CostModelVersion:       1,
			MaxProjectedRowCount:   64,
			MaxProjectedWriteBytes: 64 * 2048,
		}},
	})
	return &edgev1.SweepLeaseV1{
		LeaseVersion:         edgerecord.SweepLeaseCheckSetsVersion,
		SweepGroupId:         group,
		LeaseId:              leaseID,
		ProducerAssignmentId: assignment,
		AuthorityEpoch:       1,
		ProductionCapability: production,
		WindowStartUnixNano:  start - int64(time.Second),
		WindowEndUnixNano:    expires,
		CheckSets: []*edgev1.SweepCheckSetV1{{
			CheckSetSha256: checkKey,
			DigestVersion:  edgerecord.CheckSetDigestVersion,
			Checks:         checks,
		}},
		Slots: []*edgev1.SweepLeaseSlotV1{{
			ExecutionId:               executionID,
			SlotStartUnixNano:         start,
			CollectionExpiresUnixNano: expires,
			PlanHeader:                header,
			PlanPages:                 pages,
			SourceAuthorizations: []*edgev1.EdgeSourceAuthorizationV1{{
				Kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
				Capability:  source,
				ContextId:   executionID,
				ScopeId:     rangeID,
				ScopeSha256: targetRange.GetRangeSha256(),
			}},
		}},
	}
}

type execLeaseOp struct {
	chunks []*proto.SweepLeaseChunk
	config *proto.AgentConfigResponse
	result chan error
}

type execLeaseGateway struct {
	proto.UnimplementedAgentGatewayServiceServer
	hellos   chan []string
	refusals chan *proto.SweepLeaseSlotRefusal
	ops      chan execLeaseOp
	ended    chan struct{}
	drop     chan struct{}

	mu   sync.Mutex
	seen []*proto.ControlStreamRequest
}

func newExecLeaseGateway() *execLeaseGateway {
	return &execLeaseGateway{
		hellos:   make(chan []string, 8),
		refusals: make(chan *proto.SweepLeaseSlotRefusal, 8),
		ops:      make(chan execLeaseOp),
		ended:    make(chan struct{}, 8),
		drop:     make(chan struct{}, 1),
	}
}

func (g *execLeaseGateway) Hello(_ context.Context, req *proto.AgentHelloRequest) (*proto.AgentHelloResponse, error) {
	return &proto.AgentHelloResponse{
		Accepted:             true,
		AgentId:              req.GetAgentId(),
		GatewayId:            "disposable-gateway",
		HeartbeatIntervalSec: 30,
	}, nil
}

func (g *execLeaseGateway) GetConfig(context.Context, *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	return &proto.AgentConfigResponse{NotModified: true}, nil
}

func (g *execLeaseGateway) PushStatus(context.Context, *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func (g *execLeaseGateway) note(msg *proto.ControlStreamRequest) {
	g.mu.Lock()
	g.seen = append(g.seen, msg)
	g.mu.Unlock()
	if refusal := msg.GetSweepLeaseSlotRefusal(); refusal != nil {
		select {
		case g.refusals <- refusal:
		default:
		}
	}
}

func (g *execLeaseGateway) snapshot() []*proto.ControlStreamRequest {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := make([]*proto.ControlStreamRequest, len(g.seen))
	copy(out, g.seen)
	return out
}

func (g *execLeaseGateway) disconnect() {
	select {
	case g.drop <- struct{}{}:
	default:
	}
}

func (g *execLeaseGateway) ControlStream(stream grpc.BidiStreamingServer[proto.ControlStreamRequest, proto.ControlStreamResponse]) error {
	defer func() { g.ended <- struct{}{} }()
	incoming := make(chan *proto.ControlStreamRequest, 32)
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
		case <-g.drop:
			return nil
		case err := <-readErr:
			return err
		case msg := <-incoming:
			g.note(msg)
			if msg.GetHello() != nil {
				g.hellos <- append([]string(nil), msg.GetHello().GetCapabilities()...)
				return g.serveExec(stream, incoming, readErr)
			}
		}
	}
}

func (g *execLeaseGateway) serveExec(
	stream grpc.BidiStreamingServer[proto.ControlStreamRequest, proto.ControlStreamResponse],
	incoming <-chan *proto.ControlStreamRequest,
	readErr <-chan error,
) error {
	for {
		select {
		case <-g.drop:
			return nil
		case err := <-readErr:
			return err
		case msg := <-incoming:
			g.note(msg)
		case op := <-g.ops:
			var sendErr error
			if op.config != nil {
				sendErr = stream.Send(&proto.ControlStreamResponse{
					Payload: &proto.ControlStreamResponse_Config{Config: op.config},
				})
			} else {
				sendErr = sendLeaseChunks(stream, op.chunks)
			}
			op.result <- sendErr
			if sendErr != nil {
				return sendErr
			}
		}
	}
}

func (g *execLeaseGateway) waitHello(t *testing.T, logs *agentOutput) []string {
	t.Helper()
	select {
	case hello := <-g.hellos:
		return hello
	case <-time.After(45 * time.Second):
		t.Fatalf("agent did not open a control stream\nlog:\n%s", logs.snapshot())
	}
	return nil
}

func (g *execLeaseGateway) waitStreamEnd(t *testing.T, logs *agentOutput) {
	t.Helper()
	select {
	case <-g.ended:
	case <-time.After(15 * time.Second):
		t.Fatalf("control stream did not end\nlog:\n%s", logs.snapshot())
	}
}

func (g *execLeaseGateway) waitRefusal(t *testing.T, logs *agentOutput, budget time.Duration) *proto.SweepLeaseSlotRefusal {
	t.Helper()
	select {
	case refusal := <-g.refusals:
		return refusal
	case <-time.After(budget):
		t.Fatalf("no slot refusal\nlog:\n%s", logs.snapshot())
	}
	return nil
}

func (g *execLeaseGateway) pushLease(t *testing.T, logs *agentOutput, group string, lease *edgev1.SweepLeaseV1) *proto.SweepLeaseAck {
	t.Helper()
	op := execLeaseOp{chunks: planLeaseChunks(t, group, lease), result: make(chan error, 1)}
	select {
	case g.ops <- op:
	case <-time.After(5 * time.Second):
		t.Fatalf("control stream is not receiving a push\nlog:\n%s", logs.snapshot())
	}
	select {
	case err := <-op.result:
		if err != nil {
			t.Fatalf("lease push: %v\nlog:\n%s", err, logs.snapshot())
		}
	case <-time.After(20 * time.Second):
		t.Fatalf("lease push was not sent\nlog:\n%s", logs.snapshot())
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		for _, msg := range g.snapshot() {
			if ack := msg.GetSweepLeaseAck(); ack != nil && ack.GetPayloadSha256() == op.chunks[0].GetPayloadSha256() {
				return ack
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("no sweep lease ack\nlog:\n%s", logs.snapshot())
	return nil
}

func (g *execLeaseGateway) pushConfig(t *testing.T, logs *agentOutput, cfg *proto.AgentConfigResponse) {
	t.Helper()
	op := execLeaseOp{config: cfg, result: make(chan error, 1)}
	select {
	case g.ops <- op:
	case <-time.After(5 * time.Second):
		t.Fatalf("control stream is not receiving config\nlog:\n%s", logs.snapshot())
	}
	select {
	case err := <-op.result:
		if err != nil {
			t.Fatalf("config push: %v\nlog:\n%s", err, logs.snapshot())
		}
	case <-time.After(20 * time.Second):
		t.Fatalf("config push was not sent\nlog:\n%s", logs.snapshot())
	}
}
