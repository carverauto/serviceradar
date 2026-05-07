package agent

import (
	"context"
	"io"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/metadata"
)

type fakeControlStreamClient struct {
	sent []*proto.ControlStreamRequest
}

func (f *fakeControlStreamClient) Send(req *proto.ControlStreamRequest) error {
	f.sent = append(f.sent, req)
	return nil
}

func (f *fakeControlStreamClient) Recv() (*proto.ControlStreamResponse, error) {
	return nil, io.EOF
}

func (f *fakeControlStreamClient) Header() (metadata.MD, error) {
	return metadata.MD{}, nil
}

func (f *fakeControlStreamClient) Trailer() metadata.MD {
	return metadata.MD{}
}

func (f *fakeControlStreamClient) CloseSend() error {
	return nil
}

func (f *fakeControlStreamClient) Context() context.Context {
	return context.Background()
}

func (f *fakeControlStreamClient) SendMsg(any) error {
	return nil
}

func (f *fakeControlStreamClient) RecvMsg(any) error {
	return io.EOF
}

func TestCommandTimeoutCap_NoCommandTTLUsesCap(t *testing.T) {
	t.Parallel()

	got := commandTimeoutCap(nil)
	if got != defaultOnDemandMtrDeadline {
		t.Fatalf("expected %v, got %v", defaultOnDemandMtrDeadline, got)
	}
}

func TestCommandTimeoutCap_ExpiredReturnsZero(t *testing.T) {
	t.Parallel()

	cmd := &proto.CommandRequest{
		CreatedAt:  time.Now().Add(-2 * time.Minute).Unix(),
		TtlSeconds: 60,
	}

	got := commandTimeoutCap(cmd)
	if got != 0 {
		t.Fatalf("expected 0, got %v", got)
	}
}

func TestCommandTimeoutCap_CapsToRemainingTTL(t *testing.T) {
	t.Parallel()

	cmd := &proto.CommandRequest{
		CreatedAt:  time.Now().Add(-10 * time.Second).Unix(),
		TtlSeconds: 20,
	}

	got := commandTimeoutCap(cmd)
	if got <= 0 || got > 12*time.Second {
		t.Fatalf("expected timeout close to 10s remaining, got %v", got)
	}
}

func TestCommandTimeoutCap_UsesCapWhenTTLIsLonger(t *testing.T) {
	t.Parallel()

	cmd := &proto.CommandRequest{
		CreatedAt:  time.Now().Unix(),
		TtlSeconds: 120,
	}

	got := commandTimeoutCap(cmd)
	if got != defaultOnDemandMtrDeadline {
		t.Fatalf("expected %v, got %v", defaultOnDemandMtrDeadline, got)
	}
}

func TestOnDemandMtrOptions_UsesPayloadProtocolAndMaxHops(t *testing.T) {
	t.Parallel()

	opts := onDemandMtrOptions(mtrRunPayload{
		Target:   "8.8.8.8",
		Protocol: "udp",
		MaxHops:  12,
	})

	if opts.Target != "8.8.8.8" {
		t.Fatalf("expected target 8.8.8.8, got %q", opts.Target)
	}
	if opts.Protocol != mtr.ProtocolUDP {
		t.Fatalf("expected protocol udp, got %v", opts.Protocol)
	}
	if opts.MaxHops != 12 {
		t.Fatalf("expected max_hops 12, got %d", opts.MaxHops)
	}
}

func TestOnDemandMtrOptions_ClampsMaxHops(t *testing.T) {
	t.Parallel()

	opts := onDemandMtrOptions(mtrRunPayload{
		Target:  "1.1.1.1",
		MaxHops: 9999,
	})

	if opts.MaxHops != mtrMaxHopsUpperBound {
		t.Fatalf("expected clamped max_hops %d, got %d", mtrMaxHopsUpperBound, opts.MaxHops)
	}
}

func TestRunProxmoxCredentialTest_RejectsDirectAPITokenPayload(t *testing.T) {
	t.Parallel()

	_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
		CredentialRuleID: "rule-1",
		APIToken:         "root@pam!sr=test-secret",
		Target: proxmoxTestTarget{
			DeviceUID: "device-1",
			BaseURL:   "https://pve.example:8006",
			Hostname:  "pve-a",
		},
		TimeoutMS: 1000,
	})
	if err == nil || err.Error() != "direct proxmox api token payloads are not allowed" {
		t.Fatalf("expected direct token rejection, got %v", err)
	}
}

func TestRunProxmoxCredentialTest_RequiresCredentialBrokerGrant(t *testing.T) {
	t.Parallel()

	_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
		Target: proxmoxTestTarget{BaseURL: "https://pve.example:8006"},
	})
	if err == nil || err.Error() != "missing proxmox credential broker grant" {
		t.Fatalf("expected missing broker grant error, got %v", err)
	}
}

func TestRunProxmoxCredentialTest_BrokerGrantDoesNotExposeSecret(t *testing.T) {
	t.Parallel()

	result, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
		CredentialRuleID: "rule-1",
		CredentialBroker: proxmoxCredentialBrokerGrant{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
		},
		Target: proxmoxTestTarget{
			DeviceUID: "device-1",
			BaseURL:   "https://pve.example:8006",
			Hostname:  "pve-a",
		},
	})
	if err == nil || err.Error() != "credential broker unavailable" {
		t.Fatalf("expected broker unavailable error, got %v", err)
	}
	if result["device_uid"] != "device-1" {
		t.Fatalf("expected device_uid device-1, got %#v", result["device_uid"])
	}
	if body := result["api_token"]; body != nil {
		t.Fatalf("result leaked api_token: %#v", body)
	}
	if body := result["credential_secret_ref"]; body != nil {
		t.Fatalf("result leaked credential ref: %#v", body)
	}
}

func TestSendControlHello_IncludesRuntimeMetadata(t *testing.T) {
	t.Parallel()

	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{
		server: &Server{
			config: &ServerConfig{
				AgentID:     "agent-dusk",
				Partition:   "default",
				GatewayAddr: "gateway.demo:50051",
			},
		},
	}
	loop.setConfigVersion("cfg-123")

	if err := loop.sendControlHello(sender); err != nil {
		t.Fatalf("sendControlHello() error = %v", err)
	}

	if len(stream.sent) == 0 {
		t.Fatal("expected control stream hello to be sent")
	}

	hello := stream.sent[0].GetHello()
	if hello == nil {
		t.Fatal("expected first control stream message to be hello")
	}
	if hello.GetAgentId() != "agent-dusk" {
		t.Fatalf("hello.AgentId = %q, want %q", hello.GetAgentId(), "agent-dusk")
	}
	if hello.GetPartition() != "default" {
		t.Fatalf("hello.Partition = %q, want %q", hello.GetPartition(), "default")
	}
	if hello.GetConfigVersion() != "cfg-123" {
		t.Fatalf("hello.ConfigVersion = %q, want %q", hello.GetConfigVersion(), "cfg-123")
	}
	if hello.GetVersion() != Version {
		t.Fatalf("hello.Version = %q, want %q", hello.GetVersion(), Version)
	}
	if hello.GetHostname() == "" {
		t.Fatal("expected control stream hello hostname to be populated")
	}
	if hello.GetOs() == "" {
		t.Fatal("expected control stream hello os to be populated")
	}
	if hello.GetArch() == "" {
		t.Fatal("expected control stream hello arch to be populated")
	}
	if len(hello.GetCapabilities()) == 0 {
		t.Fatal("expected control stream hello capabilities to be populated")
	}
	if got, want := hello.GetLabels(), deploymentHelloLabels(); len(got) == 0 || got["deployment_type"] != want["deployment_type"] {
		t.Fatalf("hello.Labels = %#v, want deployment_type=%q", got, want["deployment_type"])
	}
	if hello.GetConfigSource() != "remote" {
		t.Fatalf("hello.ConfigSource = %q, want %q", hello.GetConfigSource(), "remote")
	}
}

func TestHandleConsoleFrameFailsClosedUntilPTYBridgeExists(t *testing.T) {
	t.Parallel()

	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}

	loop.handleConsoleFrame(&proto.ConsoleFrame{
		SessionId: "console-session-1",
		FrameType: consoleFrameTypeOpen,
	}, sender)

	if len(stream.sent) != 1 {
		t.Fatalf("expected one console response frame, got %d", len(stream.sent))
	}

	frame := stream.sent[0].GetConsoleFrame()
	if frame == nil {
		t.Fatal("expected console frame response")
	}
	if frame.GetSessionId() != "console-session-1" {
		t.Fatalf("SessionId = %q, want console-session-1", frame.GetSessionId())
	}
	if frame.GetFrameType() != consoleFrameTypeError {
		t.Fatalf("FrameType = %q, want %q", frame.GetFrameType(), consoleFrameTypeError)
	}
	if frame.GetReason() != "proxmox console PTY bridge unavailable" {
		t.Fatalf("Reason = %q", frame.GetReason())
	}
}
