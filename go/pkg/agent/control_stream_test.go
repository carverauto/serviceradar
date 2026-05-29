package agent

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/metadata"
)

type fakeControlStreamClient struct {
	mu   sync.Mutex
	sent []*proto.ControlStreamRequest
}

func (f *fakeControlStreamClient) Send(req *proto.ControlStreamRequest) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, req)
	return nil
}

func (f *fakeControlStreamClient) consoleFrames() []*proto.ConsoleFrame {
	f.mu.Lock()
	defer f.mu.Unlock()

	frames := make([]*proto.ConsoleFrame, 0, len(f.sent))
	for _, req := range f.sent {
		if frame := req.GetConsoleFrame(); frame != nil {
			frames = append(frames, frame)
		}
	}

	return frames
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
			GrantID:             "grant-1",
			GrantType:           "proxmox_api_token",
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

func TestRunProxmoxCredentialTest_RequiresBrokerGrantEnvelope(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		grant proxmoxCredentialBrokerGrant
	}{
		{
			name: "missing schema",
			grant: proxmoxCredentialBrokerGrant{
				GrantID:             "grant-1",
				GrantType:           "proxmox_api_token",
				CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
			},
		},
		{
			name: "missing grant type",
			grant: proxmoxCredentialBrokerGrant{
				Schema:              "serviceradar.edge_credential_broker_grant.v1",
				GrantID:             "grant-1",
				CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
				CredentialRuleID: "rule-1",
				CredentialBroker: tc.grant,
				Target:           proxmoxTestTarget{DeviceUID: "device-1", BaseURL: "https://pve.example:8006"},
			})
			if !errors.Is(err, errInvalidCredentialBrokerGrant) {
				t.Fatalf("expected invalid broker grant error, got %v", err)
			}
		})
	}
}

func TestRunProxmoxCredentialTest_DeniesGrantTargetMismatch(t *testing.T) {
	t.Parallel()

	_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
		CredentialRuleID: "rule-1",
		CredentialBroker: proxmoxCredentialBrokerGrant{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-1",
			GrantType:           "proxmox_api_token",
			CredentialRuleID:    "rule-1",
			CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
			Target: proxmoxTestTarget{
				DeviceUID: "device-2",
				BaseURL:   "https://pve.example:8006",
			},
			Allow: proxmoxCredentialBrokerACL{
				Methods: []string{"GET"},
				Paths:   []string{"/api2/json/version"},
			},
		},
		Target: proxmoxTestTarget{
			DeviceUID: "device-1",
			BaseURL:   "https://pve.example:8006",
		},
	})
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("expected grant denied error, got %v", err)
	}
}

func TestRunProxmoxCredentialTest_DeniesGrantKindAndAgentMismatch(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		target proxmoxTestTarget
	}{
		{
			name:   "kind",
			target: proxmoxTestTarget{Kind: "service", DeviceUID: "device-1", BaseURL: "https://pve.example:8006"},
		},
		{
			name: "agent",
			target: proxmoxTestTarget{
				Kind:      "device",
				DeviceUID: "device-1",
				AgentID:   "agent-2",
				BaseURL:   "https://pve.example:8006",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
				CredentialRuleID: "rule-1",
				CredentialBroker: proxmoxCredentialBrokerGrant{
					Schema:              "serviceradar.edge_credential_broker_grant.v1",
					GrantID:             "grant-1",
					GrantType:           "proxmox_api_token",
					CredentialRuleID:    "rule-1",
					CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
					Target:              tc.target,
					Allow: proxmoxCredentialBrokerACL{
						Methods: []string{"GET"},
						Paths:   []string{"/api2/json/version"},
					},
				},
				Target: proxmoxTestTarget{
					Kind:      "device",
					DeviceUID: "device-1",
					AgentID:   "agent-1",
					BaseURL:   "https://pve.example:8006",
				},
			})
			if !errors.Is(err, errCredentialBrokerGrantDenied) {
				t.Fatalf("expected grant denied error, got %v", err)
			}
		})
	}
}

func TestRunProxmoxCredentialTest_DeniesGrantHostPortPathMismatch(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		allow proxmoxCredentialBrokerACL
	}{
		{
			name:  "method",
			allow: proxmoxCredentialBrokerACL{Methods: []string{"POST"}},
		},
		{
			name:  "path",
			allow: proxmoxCredentialBrokerACL{Methods: []string{"GET"}, Paths: []string{"/api2/json/nodes"}},
		},
		{
			name: "host",
			allow: proxmoxCredentialBrokerACL{
				Methods: []string{"GET"},
				Paths:   []string{"/api2/json/version"},
				Hosts:   []string{"other.example"},
			},
		},
		{
			name: "port",
			allow: proxmoxCredentialBrokerACL{
				Methods: []string{"GET"},
				Paths:   []string{"/api2/json/version"},
				Ports:   []int{443},
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
				CredentialRuleID: "rule-1",
				CredentialBroker: proxmoxCredentialBrokerGrant{
					Schema:              "serviceradar.edge_credential_broker_grant.v1",
					GrantID:             "grant-1",
					GrantType:           "proxmox_api_token",
					CredentialRuleID:    "rule-1",
					CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
					Target: proxmoxTestTarget{
						DeviceUID: "device-1",
						BaseURL:   "https://pve.example:8006",
					},
					Allow: tc.allow,
				},
				Target: proxmoxTestTarget{
					DeviceUID: "device-1",
					BaseURL:   "https://pve.example:8006",
				},
			})
			if !errors.Is(err, errCredentialBrokerGrantDenied) {
				t.Fatalf("expected grant denied error, got %v", err)
			}
		})
	}
}

func TestRunProxmoxCredentialTest_DeniesExpiredGrant(t *testing.T) {
	t.Parallel()

	_, err := runProxmoxCredentialTest(context.Background(), proxmoxCredentialTestPayload{
		CredentialRuleID: "rule-1",
		CredentialBroker: proxmoxCredentialBrokerGrant{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-1",
			GrantType:           "proxmox_api_token",
			CredentialRuleID:    "rule-1",
			CredentialSecretRef: "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
			Target: proxmoxTestTarget{
				DeviceUID: "device-1",
				BaseURL:   "https://pve.example:8006",
			},
			Allow: proxmoxCredentialBrokerACL{
				Methods: []string{"GET"},
				Paths:   []string{"/api2/json/version"},
			},
			ExpiresAt: time.Now().Add(-time.Minute).Format(time.RFC3339),
		},
		Target: proxmoxTestTarget{
			DeviceUID: "device-1",
			BaseURL:   "https://pve.example:8006",
		},
	})
	if !errors.Is(err, errCredentialBrokerGrantExpired) {
		t.Fatalf("expected grant expired error, got %v", err)
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

	loop.handleConsoleFrame(context.Background(), &proto.ConsoleFrame{
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

func TestHandleConsoleFrameRoutesAppTCPFramesFailClosed(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		sessionID     string
		inFrameType   string
		outFrameType  string
		messageSubstr string
	}{
		{
			name:          "application",
			sessionID:     "app-session-1",
			inFrameType:   remoteaccess.FrameTypeApplicationOpen,
			outFrameType:  remoteaccess.FrameTypeApplicationError,
			messageSubstr: "invalid_open_payload",
		},
		{
			name:          "tcp",
			sessionID:     "tcp-session-1",
			inFrameType:   remoteaccess.FrameTypeTCPOpen,
			outFrameType:  remoteaccess.FrameTypeTCPError,
			messageSubstr: "invalid_open_payload",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			stream := &fakeControlStreamClient{}
			sender := newControlStreamSender(stream)
			loop := &PushLoop{}

			loop.handleConsoleFrame(context.Background(), &proto.ConsoleFrame{
				SessionId: tt.sessionID,
				FrameType: tt.inFrameType,
			}, sender)

			if len(stream.sent) != 1 {
				t.Fatalf("expected one response frame, got %d", len(stream.sent))
			}

			frame := stream.sent[0].GetConsoleFrame()
			if frame == nil {
				t.Fatal("expected response frame")
			}
			if frame.GetSessionId() != tt.sessionID {
				t.Fatalf("SessionId = %q, want %q", frame.GetSessionId(), tt.sessionID)
			}
			if frame.GetFrameType() != tt.outFrameType {
				t.Fatalf("FrameType = %q, want %q", frame.GetFrameType(), tt.outFrameType)
			}
			if !strings.Contains(string(frame.GetData()), tt.messageSubstr) {
				t.Fatalf("Data = %q", string(frame.GetData()))
			}
		})
	}
}

func TestHandleConsoleFrameExecutesApplicationHTTPRequest(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != "private-app.internal" {
			t.Fatalf("Host = %q, want private-app.internal", r.Host)
		}
		if r.URL.Path != "/allowed" {
			t.Fatalf("Path = %q, want /allowed", r.URL.Path)
		}
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	host, port := testServerHostPort(t, server.URL)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}

	openPayload := remoteaccess.ApplicationOpenPayload{
		TargetID:            "app-target-1",
		SessionID:           "app-session-1",
		Scheme:              remoteaccess.ApplicationSchemeHTTP,
		UpstreamHost:        host,
		UpstreamPort:        port,
		HostHeader:          "private-app.internal",
		AllowedMethods:      []string{"GET"},
		AllowedPathPrefixes: []string{"/allowed"},
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationOpen, openPayload), sender)
	assertApplicationConsoleFrame(t, stream.sent[0], remoteaccess.FrameTypeApplicationProgress)

	requestPayload := remoteaccess.ApplicationRequestPayload{
		RequestID: "req-1",
		SessionID: "app-session-1",
		Method:    "GET",
		Path:      "/allowed",
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationRequest, requestPayload), sender)

	if len(stream.sent) != 4 {
		t.Fatalf("sent frame count = %d, want 4", len(stream.sent))
	}
	assertApplicationConsoleFrame(t, stream.sent[1], remoteaccess.FrameTypeApplicationResponseMetadata)
	dataFrame := assertApplicationConsoleFrame(t, stream.sent[2], remoteaccess.FrameTypeApplicationData)
	assertApplicationConsoleFrame(t, stream.sent[3], remoteaccess.FrameTypeApplicationProgress)

	var dataPayload remoteaccess.ApplicationDataPayload
	if err := json.Unmarshal(dataFrame.GetData(), &dataPayload); err != nil {
		t.Fatalf("unmarshal application data: %v", err)
	}
	if string(dataPayload.Data) != "ok" {
		t.Fatalf("Data = %q, want ok", string(dataPayload.Data))
	}
}

func TestHandleConsoleFrameExecutesApplicationHTTPRequestWithBodyChunks(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("Method = %q, want POST", r.Method)
		}
		if string(body) != "chunk-onechunk-two" {
			t.Fatalf("body = %q", string(body))
		}
		_, _ = w.Write([]byte("created"))
	}))
	defer server.Close()

	host, port := testServerHostPort(t, server.URL)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}

	openPayload := remoteaccess.ApplicationOpenPayload{
		TargetID:            "app-target-1",
		SessionID:           "app-session-1",
		Scheme:              remoteaccess.ApplicationSchemeHTTP,
		UpstreamHost:        host,
		UpstreamPort:        port,
		AllowedMethods:      []string{http.MethodPost},
		AllowedPathPrefixes: []string{"/allowed"},
		QuotaPolicy:         map[string]any{"max_request_bytes": 64},
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationOpen, openPayload), sender)
	assertApplicationConsoleFrame(t, stream.sent[0], remoteaccess.FrameTypeApplicationProgress)

	requestPayload := remoteaccess.ApplicationRequestPayload{
		RequestID: "req-1",
		SessionID: "app-session-1",
		Method:    http.MethodPost,
		Path:      "/allowed",
	}
	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationRequest, requestPayload), sender)
	assertApplicationConsoleFrame(t, stream.sent[1], remoteaccess.FrameTypeApplicationProgress)

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationData, remoteaccess.ApplicationDataPayload{
		RequestID: "req-1",
		SessionID: "app-session-1",
		Direction: remoteaccess.ApplicationDataDirectionRequest,
		Sequence:  1,
		Data:      []byte("chunk-one"),
	}), sender)
	assertApplicationConsoleFrame(t, stream.sent[2], remoteaccess.FrameTypeApplicationProgress)

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationData, remoteaccess.ApplicationDataPayload{
		RequestID: "req-1",
		SessionID: "app-session-1",
		Direction: remoteaccess.ApplicationDataDirectionRequest,
		Sequence:  2,
		Data:      []byte("chunk-two"),
		EOF:       true,
	}), sender)

	if len(stream.sent) != 6 {
		t.Fatalf("sent frame count = %d, want 6", len(stream.sent))
	}
	assertApplicationConsoleFrame(t, stream.sent[3], remoteaccess.FrameTypeApplicationResponseMetadata)
	dataFrame := assertApplicationConsoleFrame(t, stream.sent[4], remoteaccess.FrameTypeApplicationData)
	progressFrame := assertApplicationConsoleFrame(t, stream.sent[5], remoteaccess.FrameTypeApplicationProgress)

	var dataPayload remoteaccess.ApplicationDataPayload
	if err := json.Unmarshal(dataFrame.GetData(), &dataPayload); err != nil {
		t.Fatalf("unmarshal application data: %v", err)
	}
	if string(dataPayload.Data) != "created" {
		t.Fatalf("Data = %q, want created", string(dataPayload.Data))
	}
	var progressPayload remoteaccess.ApplicationProgressPayload
	if err := json.Unmarshal(progressFrame.GetData(), &progressPayload); err != nil {
		t.Fatalf("unmarshal application progress: %v", err)
	}
	if progressPayload.RequestBytes != int64(len("chunk-onechunk-two")) {
		t.Fatalf("RequestBytes = %d", progressPayload.RequestBytes)
	}
}

func TestHandleConsoleFrameRejectsDuplicateApplicationOpen(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer server.Close()

	host, port := testServerHostPort(t, server.URL)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}

	openPayload := remoteaccess.ApplicationOpenPayload{
		TargetID:            "app-target-1",
		SessionID:           "app-session-1",
		Scheme:              remoteaccess.ApplicationSchemeHTTP,
		UpstreamHost:        host,
		UpstreamPort:        port,
		AllowedMethods:      []string{"GET"},
		AllowedPathPrefixes: []string{"/"},
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationOpen, openPayload), sender)
	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "app-session-1", remoteaccess.FrameTypeApplicationOpen, openPayload), sender)

	if len(stream.sent) != 2 {
		t.Fatalf("sent frame count = %d, want 2", len(stream.sent))
	}
	assertApplicationConsoleFrame(t, stream.sent[0], remoteaccess.FrameTypeApplicationProgress)
	errorFrame := assertApplicationConsoleFrame(t, stream.sent[1], remoteaccess.FrameTypeApplicationError)
	if !strings.Contains(string(errorFrame.GetData()), "session_exists") {
		t.Fatalf("Data = %q, want session_exists", string(errorFrame.GetData()))
	}
}

func TestHandleConsoleFrameExecutesTCPStream(t *testing.T) {
	t.Parallel()

	addr, closeServer := startAgentTCPEchoServer(t)
	defer closeServer()

	host, port := testNetHostPort(t, addr)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}

	openPayload := remoteaccess.TCPOpenPayload{
		TargetID:           "tcp-target-1",
		SessionID:          "tcp-session-1",
		ConnectionID:       "conn-1",
		UpstreamHost:       host,
		UpstreamPort:       port,
		IdleTimeoutSeconds: 30,
		QuotaPolicy: map[string]any{
			"max_bytes_in":  64,
			"max_bytes_out": 64,
		},
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "tcp-session-1", remoteaccess.FrameTypeTCPOpen, openPayload), sender)
	waitForConsoleFrame(t, stream, remoteaccess.FrameTypeTCPProgress)

	dataPayload := remoteaccess.TCPDataPayload{
		SessionID:    "tcp-session-1",
		ConnectionID: "conn-1",
		Direction:    remoteaccess.TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("ping"),
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "tcp-session-1", remoteaccess.FrameTypeTCPData, dataPayload), sender)

	dataFrame := waitForConsoleFrame(t, stream, remoteaccess.FrameTypeTCPData)
	var upstreamPayload remoteaccess.TCPDataPayload
	if err := json.Unmarshal(dataFrame.GetData(), &upstreamPayload); err != nil {
		t.Fatalf("unmarshal tcp data: %v", err)
	}
	if upstreamPayload.Direction != remoteaccess.TCPDataDirectionUpstream || string(upstreamPayload.Data) != "ping" {
		t.Fatalf("upstream TCP payload = %#v", upstreamPayload)
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "tcp-session-1", remoteaccess.FrameTypeTCPClose, remoteaccess.TCPClosePayload{
		SessionID:    "tcp-session-1",
		ConnectionID: "conn-1",
		Reason:       "done",
	}), sender)
	waitForConsoleFrame(t, stream, remoteaccess.FrameTypeTCPClose)
}

func TestHandleConsoleFrameClosesTCPSessionWhenContextCancels(t *testing.T) {
	t.Parallel()

	addr, closeServer := startAgentTCPEchoServer(t)
	defer closeServer()

	host, port := testNetHostPort(t, addr)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}
	ctx, cancel := context.WithCancel(context.Background())

	openPayload := remoteaccess.TCPOpenPayload{
		TargetID:               "tcp-target-1",
		SessionID:              "tcp-session-1",
		ConnectionID:           "conn-1",
		UpstreamHost:           host,
		UpstreamPort:           port,
		IdleTimeoutSeconds:     30,
		AbsoluteTimeoutSeconds: 30,
		QuotaPolicy: map[string]any{
			"max_bytes_in":  64,
			"max_bytes_out": 64,
		},
	}

	loop.handleConsoleFrame(ctx, jsonConsoleFrame(t, "tcp-session-1", remoteaccess.FrameTypeTCPOpen, openPayload), sender)
	waitForConsoleFrame(t, stream, remoteaccess.FrameTypeTCPProgress)

	cancel()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if loop.tcpAdapter("tcp-session-1") == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatal("tcp adapter remained registered after control context cancellation")
}

func TestHandleConsoleFrameClosesTCPSessionAfterWriteQuotaError(t *testing.T) {
	t.Parallel()

	addr, closeServer, upstreamClosed := startAgentTCPReadCloseServer(t)
	defer closeServer()

	host, port := testNetHostPort(t, addr)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{}

	openPayload := remoteaccess.TCPOpenPayload{
		TargetID:           "tcp-target-1",
		SessionID:          "tcp-session-1",
		ConnectionID:       "conn-1",
		UpstreamHost:       host,
		UpstreamPort:       port,
		IdleTimeoutSeconds: 30,
		QuotaPolicy: map[string]any{
			"max_bytes_in": 3,
		},
	}

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "tcp-session-1", remoteaccess.FrameTypeTCPOpen, openPayload), sender)
	waitForConsoleFrame(t, stream, remoteaccess.FrameTypeTCPProgress)

	loop.handleConsoleFrame(context.Background(), jsonConsoleFrame(t, "tcp-session-1", remoteaccess.FrameTypeTCPData, remoteaccess.TCPDataPayload{
		SessionID:    "tcp-session-1",
		ConnectionID: "conn-1",
		Direction:    remoteaccess.TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("toolong"),
	}), sender)

	waitForConsoleFrame(t, stream, remoteaccess.FrameTypeTCPError)
	if loop.tcpAdapter("tcp-session-1") != nil {
		t.Fatal("tcp adapter remained registered after write quota error")
	}

	select {
	case <-upstreamClosed:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream TCP connection was not closed after write quota error")
	}
}

func TestAgentCapabilitiesAdvertiseRemoteAccessAndGateBPF(t *testing.T) {
	t.Parallel()

	base := agentCapabilities(agentCapabilityOptions{})
	for _, capability := range []string{
		remoteaccess.CapabilityRemoteAccess,
		remoteaccess.CapabilityRemoteAccessSSH,
		remoteaccess.CapabilityRemoteAccessApp,
		remoteaccess.CapabilityRemoteAccessTCP,
		remoteaccess.CapabilityRemoteAccessFile,
		remoteaccess.CapabilityRemoteAccessSFTP,
		remoteaccess.CapabilityRemoteAccessRecording,
		capabilityHostNetworkVisibility,
		capabilityHostNetworkVisibilityFingerprintUnavailable,
		capabilityHostNetworkVisibilityDPIUnavailable,
		capabilityHostNetworkVisibilityFlowUnavailable,
		capabilityHostNetworkVisibilitySnapshotUnavailable,
		capabilitySweepBannerGrab,
		capabilitySweepBannerGrabUnavailable,
	} {
		if !slices.Contains(base, capability) {
			t.Fatalf("base capabilities missing %q: %#v", capability, base)
		}
	}
	if slices.Contains(base, remoteaccess.CapabilityRemoteAccessBPF) {
		t.Fatalf("base capabilities should not advertise BPF: %#v", base)
	}
	if slices.Contains(base, remoteaccess.CapabilityRemoteAccessRDP) ||
		slices.Contains(base, remoteaccess.CapabilityRemoteAccessDesktop) {
		t.Fatalf("base capabilities should not advertise RDP: %#v", base)
	}
	if slices.Contains(base, capabilityHostNetworkVisibilityFingerprintEnabled) {
		t.Fatalf("base capabilities should not advertise enabled fingerprinting: %#v", base)
	}
	if slices.Contains(base, capabilitySweepBannerGrabAvailable) {
		t.Fatalf("base capabilities should not advertise available banner grab: %#v", base)
	}

	withNetprobe := agentCapabilities(agentCapabilityOptions{hostNetworkVisibilityFingerprintEnabled: true})
	if !slices.Contains(withNetprobe, capabilityHostNetworkVisibilityFingerprintEnabled) {
		t.Fatalf("netprobe capabilities missing enabled fingerprinting: %#v", withNetprobe)
	}
	if slices.Contains(withNetprobe, capabilityHostNetworkVisibilityFingerprintUnavailable) {
		t.Fatalf("netprobe capabilities should not advertise unavailable fingerprinting: %#v", withNetprobe)
	}

	withBannerGrab := agentCapabilities(agentCapabilityOptions{sweepBannerGrabAvailable: true})
	if !slices.Contains(withBannerGrab, capabilitySweepBannerGrabAvailable) {
		t.Fatalf("banner grab capabilities missing available state: %#v", withBannerGrab)
	}
	if slices.Contains(withBannerGrab, capabilitySweepBannerGrabUnavailable) {
		t.Fatalf("banner grab capabilities should not advertise unavailable state: %#v", withBannerGrab)
	}

	withBPF := agentCapabilities(agentCapabilityOptions{enhancedBPF: true})
	if !slices.Contains(withBPF, remoteaccess.CapabilityRemoteAccessBPF) {
		t.Fatalf("BPF capabilities missing %q: %#v", remoteaccess.CapabilityRemoteAccessBPF, withBPF)
	}

	withRDP := agentCapabilities(agentCapabilityOptions{desktopRDP: true})
	for _, capability := range []string{
		remoteaccess.CapabilityRemoteAccessDesktop,
		remoteaccess.CapabilityRemoteAccessRDP,
	} {
		if !slices.Contains(withRDP, capability) {
			t.Fatalf("RDP capabilities missing %q: %#v", capability, withRDP)
		}
	}
}

func TestRemoteAccessRDPCapabilityRequiresConfigAndHelper(t *testing.T) {
	t.Parallel()

	enabled := true
	disabled := false
	dir := t.TempDir()
	adapterPath := filepath.Join(dir, remoteaccess.DefaultRDPAdapterBinary)
	if err := os.WriteFile(adapterPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}
	readyAdapterPath := filepath.Join(dir, "ready-"+remoteaccess.DefaultRDPAdapterBinary)
	readyScript := "#!/bin/sh\n" +
		"if [ \"$1\" = \"--capabilities\" ]; then\n" +
		"  echo '{\"schema\":\"serviceradar.rdp.helper.capabilities.v1\",\"protocol\":\"rdp\",\"helper_protocol_version\":1,\"ironrdp_backend_linked\":true,\"connector_ready\":true}'\n" +
		"  exit 0\n" +
		"fi\n" +
		"exit 0\n"
	if err := os.WriteFile(readyAdapterPath, []byte(readyScript), 0o755); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}

	cases := []struct {
		name string
		cfg  *ServerConfig
		want bool
	}{
		{name: "nil config", cfg: nil},
		{name: "default disabled", cfg: &ServerConfig{RemoteAccessRDPAdapterPath: adapterPath}},
		{name: "explicit disabled", cfg: &ServerConfig{RemoteAccessRDPEnabled: &disabled, RemoteAccessRDPAdapterPath: adapterPath}},
		{name: "enabled missing helper", cfg: &ServerConfig{RemoteAccessRDPEnabled: &enabled, RemoteAccessRDPAdapterPath: filepath.Join(dir, "missing")}},
		{name: "enabled executable helper without ready connector", cfg: &ServerConfig{RemoteAccessRDPEnabled: &enabled, RemoteAccessRDPAdapterPath: adapterPath}},
		{name: "enabled ready helper", cfg: &ServerConfig{RemoteAccessRDPEnabled: &enabled, RemoteAccessRDPAdapterPath: readyAdapterPath}, want: true},
	}
	for _, tc := range cases {
		if got := remoteAccessRDPCapabilityEnabled(tc.cfg); got != tc.want {
			t.Fatalf("%s: remoteAccessRDPCapabilityEnabled = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func jsonConsoleFrame(t *testing.T, sessionID string, frameType string, payload any) *proto.ConsoleFrame {
	t.Helper()

	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	return &proto.ConsoleFrame{
		SessionId: sessionID,
		FrameType: frameType,
		Data:      data,
	}
}

func assertApplicationConsoleFrame(t *testing.T, req *proto.ControlStreamRequest, frameType string) *proto.ConsoleFrame {
	t.Helper()

	frame := req.GetConsoleFrame()
	if frame == nil {
		t.Fatal("expected console frame")
	}
	if frame.GetSessionId() != "app-session-1" {
		t.Fatalf("SessionId = %q, want app-session-1", frame.GetSessionId())
	}
	if frame.GetFrameType() != frameType {
		t.Fatalf("FrameType = %q, want %q", frame.GetFrameType(), frameType)
	}

	return frame
}

func testServerHostPort(t *testing.T, rawURL string) (string, int) {
	t.Helper()

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}

	return testNetHostPort(t, parsed.Host)
}

func testNetHostPort(t *testing.T, address string) (string, int) {
	t.Helper()

	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatalf("split host port: %v", err)
	}

	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatalf("parse server port: %v", err)
	}

	return host, port
}

func waitForConsoleFrame(t *testing.T, stream *fakeControlStreamClient, frameType string) *proto.ConsoleFrame {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, frame := range stream.consoleFrames() {
			if frame.GetFrameType() == frameType {
				return frame
			}
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("timed out waiting for frame type %q; frames=%#v", frameType, stream.consoleFrames())
	return nil
}

func startAgentTCPEchoServer(t *testing.T) (string, func()) {
	t.Helper()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen tcp: %v", err)
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()

	return listener.Addr().String(), func() {
		_ = listener.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("tcp echo server did not stop")
		}
	}
}

func startAgentTCPReadCloseServer(t *testing.T) (string, func(), <-chan struct{}) {
	t.Helper()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen tcp: %v", err)
	}

	accepted := make(chan net.Conn, 1)
	upstreamClosed := make(chan struct{})
	done := make(chan struct{})

	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			close(upstreamClosed)
			return
		}
		accepted <- conn
		_, _ = io.Copy(io.Discard, conn)
		_ = conn.Close()
		close(upstreamClosed)
	}()

	closeServer := func() {
		_ = listener.Close()
		select {
		case conn := <-accepted:
			_ = conn.Close()
		default:
		}
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("tcp read-close server did not stop")
		}
	}

	return listener.Addr().String(), closeServer, upstreamClosed
}
