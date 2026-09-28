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
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

const (
	grpcTestHost   = "192.0.2.10"
	grpcTestPort   = 9200
	grpcTestMethod = "/example.v1.Device/Handle"

	grpcTestRequestPtr  = uint32(0)
	grpcTestResponsePtr = uint32(32 * 1024)
	grpcTestResponseLen = uint32(32 * 1024)
)

var errGRPCTestDialRefused = errors.New("connection refused")

// grpcTestServerCall is what the in-process server observed for one RPC.
type grpcTestServerCall struct {
	method   string
	message  []byte
	metadata metadata.MD
}

// grpcTestServer is an in-process gRPC server reached over bufconn. Its handler
// sees raw request bytes, so no generated protobuf code is involved.
type grpcTestServer struct {
	listener *bufconn.Listener

	mu      sync.Mutex
	calls   []grpcTestServerCall
	dials   []string
	handler func(stream grpc.ServerStream, call grpcTestServerCall) error
}

func newGRPCTestServer(t *testing.T, opts ...grpc.ServerOption) *grpcTestServer {
	t.Helper()

	srv := &grpcTestServer{listener: bufconn.Listen(1 << 20)}
	opts = append(opts,
		grpc.ForceServerCodec(pluginGRPCRawCodec{}),
		grpc.UnknownServiceHandler(srv.handle),
	)
	server := grpc.NewServer(opts...)
	go func() {
		_ = server.Serve(srv.listener)
	}()
	t.Cleanup(server.Stop)

	return srv
}

func (s *grpcTestServer) handle(_ any, stream grpc.ServerStream) error {
	method, _ := grpc.MethodFromServerStream(stream)
	var request []byte
	if err := stream.RecvMsg(&request); err != nil {
		return err
	}
	md, _ := metadata.FromIncomingContext(stream.Context())
	call := grpcTestServerCall{method: method, message: request, metadata: md}

	s.mu.Lock()
	s.calls = append(s.calls, call)
	handler := s.handler
	s.mu.Unlock()

	if handler == nil {
		return stream.SendMsg(&request)
	}
	return handler(stream, call)
}

func (s *grpcTestServer) setHandler(handler func(stream grpc.ServerStream, call grpcTestServerCall) error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handler = handler
}

func (s *grpcTestServer) dialer() pluginGRPCDialer {
	return func(ctx context.Context, addr string) (net.Conn, error) {
		s.mu.Lock()
		s.dials = append(s.dials, addr)
		s.mu.Unlock()
		return s.listener.DialContext(ctx)
	}
}

func (s *grpcTestServer) observed() ([]grpcTestServerCall, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]grpcTestServerCall(nil), s.calls...), append([]string(nil), s.dials...)
}

func grpcTestPermissions() pluginPermissions {
	return pluginPermissions{
		AllowedNetworks: []string{"192.0.2.0/24"},
		AllowedPorts:    []int{grpcTestPort},
	}
}

func newPluginGRPCHostTestExecution(
	t *testing.T,
	permissions pluginPermissions,
	capabilities map[string]bool,
	httpClient *http.Client,
) (*pluginExecution, api.Module) {
	t.Helper()

	permissions.normalize()
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:     logger.NewTestLogger(),
		HTTPClient: httpClient,
	})
	t.Cleanup(manager.Stop)

	assignment := &pluginAssignment{
		AssignmentID: "grpc-unary-test",
		PluginID:     "grpc-unary-test",
		Capabilities: capabilities,
		Permissions:  permissions,
		Timeout:      5 * time.Second,
	}

	runtime := wazero.NewRuntime(t.Context())
	t.Cleanup(func() {
		_ = runtime.Close(t.Context())
	})

	// Minimal Wasm module exporting one memory page, so requests and responses
	// cross the real api.Module memory boundary.
	module, err := runtime.Instantiate(t.Context(), []byte{
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		0x05, 0x03, 0x01, 0x00, 0x01,
		0x07, 0x0a, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
	})
	if err != nil {
		t.Fatalf("instantiate test Wasm module: %v", err)
	}

	return newPluginExecution(manager, assignment), module
}

func newGRPCExecForServer(t *testing.T, srv *grpcTestServer, permissions pluginPermissions) (*pluginExecution, api.Module) {
	t.Helper()

	exec, mod := newPluginGRPCHostTestExecution(t, permissions, map[string]bool{pluginCapabilityGRPCRequest: true}, nil)
	if srv != nil {
		exec.grpcDialer = srv.dialer()
	}
	return exec, mod
}

func grpcTestRequest(message []byte) grpcUnaryRequestPayload {
	return grpcUnaryRequestPayload{
		TargetHost:    grpcTestHost,
		TargetPort:    grpcTestPort,
		Method:        grpcTestMethod,
		MessageBase64: base64.StdEncoding.EncodeToString(message),
		TimeoutMS:     5000,
		Transport:     pluginGRPCTransportH2C,
	}
}

func callPluginHostGRPCUnary(
	t *testing.T,
	exec *pluginExecution,
	mod api.Module,
	request any,
	respLen uint32,
) (int32, grpcUnaryResponsePayload) {
	t.Helper()

	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal gRPC request payload: %v", err)
	}
	if !mod.Memory().Write(grpcTestRequestPtr, payload) {
		t.Fatal("write gRPC request payload to Wasm memory")
	}

	got := exec.hostGRPCUnary(t.Context(), mod, grpcTestRequestPtr, uint32(len(payload)), grpcTestResponsePtr, respLen)

	var response grpcUnaryResponsePayload
	if got > 0 {
		raw, ok := mod.Memory().Read(grpcTestResponsePtr, uint32(got))
		if !ok {
			t.Fatal("read gRPC response from Wasm memory")
		}
		if err := json.Unmarshal(raw, &response); err != nil {
			t.Fatalf("decode gRPC response %q: %v", raw, err)
		}
	}
	return got, response
}

func decodeGRPCTestMessage(t *testing.T, response grpcUnaryResponsePayload) []byte {
	t.Helper()

	message, err := base64.StdEncoding.DecodeString(response.MessageBase64)
	if err != nil {
		t.Fatalf("decode response message_base64: %v", err)
	}
	return message
}

func TestPluginHostGRPCUnaryOKCall(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	srv.setHandler(func(stream grpc.ServerStream, call grpcTestServerCall) error {
		if err := stream.SetHeader(metadata.Pairs("x-served-by", "test-server")); err != nil {
			return err
		}
		stream.SetTrailer(metadata.Pairs("x-trailer-bin", string([]byte{0x00, 0xff})))
		reply := append([]byte("reply:"), call.message...)
		return stream.SendMsg(&reply)
	})
	exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

	request := grpcTestRequest([]byte{0x0a, 0x03, 'a', 'b', 'c'})
	request.Metadata = map[string]string{
		"X-Client-Tag": "example-tag",
		"trace-bin":    base64.StdEncoding.EncodeToString([]byte{0x01, 0x02}),
	}
	got, response := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
	if got <= 0 {
		t.Fatalf("hostGRPCUnary() = %d, want response length", got)
	}

	if response.GRPCStatus != int(codes.OK) || response.GRPCMessage != "" {
		t.Fatalf("status = %d %q, want OK", response.GRPCStatus, response.GRPCMessage)
	}
	if message := decodeGRPCTestMessage(t, response); !bytes.Equal(message, []byte("reply:\x0a\x03abc")) {
		t.Fatalf("response message = %q", message)
	}
	if values := response.Headers["x-served-by"]; len(values) != 1 || values[0] != "test-server" {
		t.Fatalf("headers = %#v, want x-served-by", response.Headers)
	}
	if values := response.Trailers["x-trailer-bin"]; len(values) != 1 ||
		values[0] != base64.StdEncoding.EncodeToString([]byte{0x00, 0xff}) {
		t.Fatalf("trailers = %#v, want base64 x-trailer-bin", response.Trailers)
	}

	calls, dials := srv.observed()
	if len(calls) != 1 || calls[0].method != grpcTestMethod {
		t.Fatalf("server calls = %#v, want one %s", calls, grpcTestMethod)
	}
	if !bytes.Equal(calls[0].message, []byte{0x0a, 0x03, 'a', 'b', 'c'}) {
		t.Fatalf("server request = %q", calls[0].message)
	}
	if values := calls[0].metadata.Get("x-client-tag"); len(values) != 1 || values[0] != "example-tag" {
		t.Fatalf("server metadata x-client-tag = %#v (keys must be lowercased)", values)
	}
	if values := calls[0].metadata.Get("trace-bin"); len(values) != 1 || values[0] != "\x01\x02" {
		t.Fatalf("server metadata trace-bin = %#v, want decoded binary", values)
	}
	if len(dials) != 1 || dials[0] != net.JoinHostPort(grpcTestHost, "9200") {
		t.Fatalf("dials = %#v, want the permitted address", dials)
	}
	if exec.transientConns != 0 || exec.manager.openConnections != 0 {
		t.Fatalf("connection accounting leaked: exec=%d manager=%d", exec.transientConns, exec.manager.openConnections)
	}
}

func TestPluginHostGRPCUnaryEmptyRequestMessage(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

	got, response := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest(nil), grpcTestResponseLen)
	if got <= 0 || response.GRPCStatus != int(codes.OK) {
		t.Fatalf("hostGRPCUnary() = %d status %d, want OK", got, response.GRPCStatus)
	}
	if response.MessageBase64 != "" {
		t.Fatalf("message_base64 = %q, want empty echo", response.MessageBase64)
	}
}

func TestPluginHostGRPCUnaryNonOKStatusCarriesTrailers(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	srv.setHandler(func(stream grpc.ServerStream, _ grpcTestServerCall) error {
		stream.SetTrailer(metadata.Pairs("x-error-detail", "device-missing"))
		return status.Error(codes.NotFound, "no such device")
	})
	exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

	got, response := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), grpcTestResponseLen)
	if got <= 0 {
		t.Fatalf("hostGRPCUnary() = %d, want a completed-RPC response", got)
	}
	if response.GRPCStatus != int(codes.NotFound) || response.GRPCMessage != "no such device" {
		t.Fatalf("status = %d %q, want NOT_FOUND", response.GRPCStatus, response.GRPCMessage)
	}
	if values := response.Trailers["x-error-detail"]; len(values) != 1 || values[0] != "device-missing" {
		t.Fatalf("trailers = %#v, want x-error-detail", response.Trailers)
	}
	if response.MessageBase64 != "" || response.Headers == nil {
		t.Fatalf("response = %#v, want empty message and non-nil headers", response)
	}
}

func TestPluginHostGRPCUnaryTransportFailureIsUnavailable(t *testing.T) {
	t.Parallel()

	exec, mod := newGRPCExecForServer(t, nil, grpcTestPermissions())
	exec.grpcDialer = func(context.Context, string) (net.Conn, error) {
		return nil, errGRPCTestDialRefused
	}

	got, response := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), grpcTestResponseLen)
	if got <= 0 {
		t.Fatalf("hostGRPCUnary() = %d, want UNAVAILABLE response", got)
	}
	if response.GRPCStatus != int(codes.Unavailable) || response.GRPCMessage == "" {
		t.Fatalf("status = %d %q, want UNAVAILABLE with message", response.GRPCStatus, response.GRPCMessage)
	}
}

func TestPluginHostGRPCUnaryDeniesUndeclaredCapability(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	exec, mod := newPluginGRPCHostTestExecution(t, grpcTestPermissions(), map[string]bool{"http_request": true}, nil)
	exec.grpcDialer = srv.dialer()

	got, _ := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), grpcTestResponseLen)
	if got != pluginErrDenied {
		t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrDenied)
	}
	if _, dials := srv.observed(); len(dials) != 0 {
		t.Fatalf("dials = %#v, want none", dials)
	}
}

func TestPluginHostGRPCUnaryDeniesDestinationBeforeDial(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		permissions pluginPermissions
		mutate      func(*grpcUnaryRequestPayload)
	}{
		{
			name:        "address outside allowed networks",
			permissions: grpcTestPermissions(),
			mutate:      func(r *grpcUnaryRequestPayload) { r.TargetHost = "198.51.100.10" },
		},
		{
			name:        "port not allowed",
			permissions: grpcTestPermissions(),
			mutate:      func(r *grpcUnaryRequestPayload) { r.TargetPort = 9201 },
		},
		{
			name: "no port allowlist",
			permissions: pluginPermissions{
				AllowedNetworks: []string{"192.0.2.0/24"},
			},
		},
		{
			name: "hostname outside allowed domains",
			permissions: pluginPermissions{
				AllowedDomains: []string{"device.example.com"},
				AllowedPorts:   []int{grpcTestPort},
			},
			mutate: func(r *grpcUnaryRequestPayload) {
				r.TargetHost = "other.example.com"
				r.Transport = pluginGRPCTransportTLS
			},
		},
		{
			name: "domain wildcard does not authorize an ip literal",
			permissions: pluginPermissions{
				AllowedDomains: []string{"*"},
				AllowedPorts:   []int{grpcTestPort},
			},
			mutate: func(r *grpcUnaryRequestPayload) { r.Transport = pluginGRPCTransportTLS },
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			srv := newGRPCTestServer(t)
			exec, mod := newGRPCExecForServer(t, srv, tc.permissions)

			request := grpcTestRequest([]byte("req"))
			if tc.mutate != nil {
				tc.mutate(&request)
			}
			got, _ := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
			if got != pluginErrDenied {
				t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrDenied)
			}
			if _, dials := srv.observed(); len(dials) != 0 {
				t.Fatalf("dials = %#v, want none", dials)
			}
		})
	}
}

func TestPluginHostGRPCUnaryRefusesH2COutsideAllowedNetworks(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		permissions pluginPermissions
		host        string
	}{
		{
			name: "hostname permitted only by allowed domains",
			permissions: pluginPermissions{
				AllowedDomains: []string{"device.example.com"},
				AllowedPorts:   []int{grpcTestPort},
			},
			host: "device.example.com",
		},
		{
			name: "ip literal permitted only by an exact allowed domain entry",
			permissions: pluginPermissions{
				AllowedDomains: []string{grpcTestHost},
				AllowedPorts:   []int{grpcTestPort},
			},
			host: grpcTestHost,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			srv := newGRPCTestServer(t)
			exec, mod := newGRPCExecForServer(t, srv, tc.permissions)

			request := grpcTestRequest([]byte("req"))
			request.TargetHost = tc.host
			got, _ := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
			if got != pluginErrDenied {
				t.Fatalf("hostGRPCUnary() h2c = %d, want %d", got, pluginErrDenied)
			}
			if _, dials := srv.observed(); len(dials) != 0 {
				t.Fatalf("dials = %#v, want none", dials)
			}

			// The same destination is permitted over TLS; the plain-text test
			// server fails the handshake, which proves the call was dialed.
			request.Transport = pluginGRPCTransportTLS
			got, response := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
			if got <= 0 || response.GRPCStatus != int(codes.Unavailable) {
				t.Fatalf("hostGRPCUnary() tls = %d status %d, want UNAVAILABLE response", got, response.GRPCStatus)
			}
			if _, dials := srv.observed(); len(dials) == 0 {
				t.Fatal("tls call was not dialed")
			}
		})
	}
}

func TestPluginHostGRPCUnaryTLSUsesHostTrustRoots(t *testing.T) {
	t.Parallel()

	caPEM, leaf := newPrivateCAAndLeaf(t, net.ParseIP(grpcTestHost))
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(caPEM)) {
		t.Fatal("append test CA")
	}

	srv := newGRPCTestServer(t, grpc.Creds(credentials.NewServerTLSFromCert(&leaf)))
	httpClient := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool},
	}}
	exec, mod := newPluginGRPCHostTestExecution(
		t,
		grpcTestPermissions(),
		map[string]bool{pluginCapabilityGRPCRequest: true},
		httpClient,
	)
	exec.grpcDialer = srv.dialer()

	request := grpcTestRequest([]byte("secure"))
	request.Transport = pluginGRPCTransportTLS
	got, response := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
	if got <= 0 || response.GRPCStatus != int(codes.OK) {
		t.Fatalf("hostGRPCUnary() = %d status %d %q, want OK", got, response.GRPCStatus, response.GRPCMessage)
	}
	if message := decodeGRPCTestMessage(t, response); string(message) != "secure" {
		t.Fatalf("response message = %q", message)
	}

	// Without the configured CA the certificate does not verify.
	untrusted, untrustedMod := newGRPCExecForServer(t, srv, grpcTestPermissions())
	got, response = callPluginHostGRPCUnary(t, untrusted, untrustedMod, request, grpcTestResponseLen)
	if got <= 0 || response.GRPCStatus != int(codes.Unavailable) {
		t.Fatalf("untrusted hostGRPCUnary() = %d status %d, want UNAVAILABLE", got, response.GRPCStatus)
	}
}

func TestPluginHostGRPCUnaryTLSFailsClosedWhenTrustUnavailable(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	exec, mod := newPluginGRPCHostTestExecution(
		t,
		grpcTestPermissions(),
		map[string]bool{pluginCapabilityGRPCRequest: true},
		unavailablePluginHTTPClient(nil),
	)
	exec.grpcDialer = srv.dialer()

	request := grpcTestRequest([]byte("req"))
	request.Transport = pluginGRPCTransportTLS
	got, _ := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
	if got != pluginErrInternal {
		t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrInternal)
	}
	if _, dials := srv.observed(); len(dials) != 0 {
		t.Fatalf("dials = %#v, want none", dials)
	}
}

func TestPluginHostGRPCUnaryOversizedResponse(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	srv.setHandler(func(stream grpc.ServerStream, _ grpcTestServerCall) error {
		reply := bytes.Repeat([]byte{0x42}, 2048)
		return stream.SendMsg(&reply)
	})

	t.Run("exceeds max_response_bytes", func(t *testing.T) {
		t.Parallel()

		exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())
		request := grpcTestRequest([]byte("req"))
		request.MaxResponseBytes = 1024
		got, _ := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
		if got != pluginErrTooLarge {
			t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrTooLarge)
		}
	})

	t.Run("does not fit the guest buffer", func(t *testing.T) {
		t.Parallel()

		exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())
		got, _ := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), 512)
		if got != pluginErrTooLarge {
			t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrTooLarge)
		}
	})

	t.Run("server resource exhausted is a completed rpc", func(t *testing.T) {
		t.Parallel()

		busy := newGRPCTestServer(t)
		busy.setHandler(func(grpc.ServerStream, grpcTestServerCall) error {
			return status.Error(codes.ResourceExhausted, "quota exceeded")
		})
		exec, mod := newGRPCExecForServer(t, busy, grpcTestPermissions())
		got, response := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), grpcTestResponseLen)
		if got <= 0 || response.GRPCStatus != int(codes.ResourceExhausted) {
			t.Fatalf("hostGRPCUnary() = %d status %d, want RESOURCE_EXHAUSTED response", got, response.GRPCStatus)
		}
	})
}

func TestPluginHostGRPCUnaryTimeout(t *testing.T) {
	t.Parallel()

	t.Run("no response before the local deadline", func(t *testing.T) {
		t.Parallel()

		srv := newGRPCTestServer(t)
		// The handler never answers, not even on its own deadline, so only the
		// host's timer can end the call.
		release := make(chan struct{})
		t.Cleanup(func() { close(release) })
		srv.setHandler(func(grpc.ServerStream, grpcTestServerCall) error {
			<-release
			return status.Error(codes.Unavailable, "handler released")
		})
		exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

		request := grpcTestRequest([]byte("req"))
		request.TimeoutMS = 50
		started := time.Now()
		got, _ := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
		if got != pluginErrTimeout {
			t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrTimeout)
		}
		if elapsed := time.Since(started); elapsed > 3*time.Second {
			t.Fatalf("timeout took %s, want it bounded by timeout_ms", elapsed)
		}
	})

	t.Run("server reports the propagated deadline", func(t *testing.T) {
		t.Parallel()

		srv := newGRPCTestServer(t)
		srv.setHandler(func(grpc.ServerStream, grpcTestServerCall) error {
			return status.Error(codes.DeadlineExceeded, "deadline exceeded upstream")
		})
		exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

		got, _ := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), grpcTestResponseLen)
		if got != pluginErrTimeout {
			t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrTimeout)
		}
	})
}

func TestPluginHostGRPCUnaryRejectsInvalidRequests(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*grpcUnaryRequestPayload)
	}{
		{name: "grpc- metadata key", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{"grpc-timeout": "1S"}
		}},
		{name: "pseudo header", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{":authority": "device.example.com"}
		}},
		{name: "reserved content-type", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{"Content-Type": "application/grpc"}
		}},
		{name: "reserved te", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{"te": "trailers"}
		}},
		{name: "illegal key character", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{"x request": "1"}
		}},
		{name: "non-printable value", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{"x-note": "line\nbreak"}
		}},
		{name: "binary value not base64", mutate: func(r *grpcUnaryRequestPayload) {
			r.Metadata = map[string]string{"x-trace-bin": "!!not-base64!!"}
		}},
		{name: "method without service", mutate: func(r *grpcUnaryRequestPayload) { r.Method = "/Handle" }},
		{name: "method without leading slash", mutate: func(r *grpcUnaryRequestPayload) {
			r.Method = "example.v1.Device/Handle"
		}},
		{name: "unknown transport", mutate: func(r *grpcUnaryRequestPayload) { r.Transport = "http" }},
		{name: "missing transport", mutate: func(r *grpcUnaryRequestPayload) { r.Transport = "" }},
		{name: "port out of range", mutate: func(r *grpcUnaryRequestPayload) { r.TargetPort = 70000 }},
		{name: "empty host", mutate: func(r *grpcUnaryRequestPayload) { r.TargetHost = "" }},
		{name: "host with path", mutate: func(r *grpcUnaryRequestPayload) { r.TargetHost = "device.example.com/x" }},
		{name: "message not base64", mutate: func(r *grpcUnaryRequestPayload) { r.MessageBase64 = "%%%" }},
		{name: "negative timeout", mutate: func(r *grpcUnaryRequestPayload) { r.TimeoutMS = -1 }},
		{name: "negative max response", mutate: func(r *grpcUnaryRequestPayload) { r.MaxResponseBytes = -1 }},
		{name: "authority with path", mutate: func(r *grpcUnaryRequestPayload) {
			r.Authority = "device.example.com/extra"
		}},
		{name: "authority with whitespace", mutate: func(r *grpcUnaryRequestPayload) {
			r.Authority = "device example.com"
		}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			srv := newGRPCTestServer(t)
			exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

			request := grpcTestRequest([]byte("req"))
			tc.mutate(&request)
			got, _ := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
			if got != pluginErrInvalid {
				t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrInvalid)
			}
			if _, dials := srv.observed(); len(dials) != 0 {
				t.Fatalf("dials = %#v, want none", dials)
			}
		})
	}

	t.Run("malformed json", func(t *testing.T) {
		t.Parallel()

		exec, mod := newGRPCExecForServer(t, nil, grpcTestPermissions())
		payload := []byte(`{"target_host":`)
		if !mod.Memory().Write(grpcTestRequestPtr, payload) {
			t.Fatal("write payload")
		}
		got := exec.hostGRPCUnary(t.Context(), mod, grpcTestRequestPtr, uint32(len(payload)), grpcTestResponsePtr, grpcTestResponseLen)
		if got != pluginErrInvalid {
			t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrInvalid)
		}
	})
}

func TestPluginHostGRPCUnaryAuthorityOverride(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	var authority string
	srv.setHandler(func(stream grpc.ServerStream, call grpcTestServerCall) error {
		if values := call.metadata.Get(":authority"); len(values) > 0 {
			authority = values[0]
		}
		return stream.SendMsg(&call.message)
	})
	exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())

	request := grpcTestRequest([]byte("req"))
	request.Authority = "device.example.com"
	got, response := callPluginHostGRPCUnary(t, exec, mod, request, grpcTestResponseLen)
	if got <= 0 || response.GRPCStatus != int(codes.OK) {
		t.Fatalf("hostGRPCUnary() = %d status %d, want OK", got, response.GRPCStatus)
	}
	if authority != "device.example.com" {
		t.Fatalf(":authority = %q, want override", authority)
	}
	if _, dials := srv.observed(); len(dials) != 1 || dials[0] != net.JoinHostPort(grpcTestHost, "9200") {
		t.Fatalf("dials = %#v, want target_host, not the authority", dials)
	}
}

func TestPluginHostGRPCUnaryHonorsMaxOpenConnections(t *testing.T) {
	t.Parallel()

	srv := newGRPCTestServer(t)
	exec, mod := newGRPCExecForServer(t, srv, grpcTestPermissions())
	exec.assignment.Resources.MaxOpenConnections = 1

	client, peer := net.Pipe()
	t.Cleanup(func() {
		_ = client.Close()
		_ = peer.Close()
	})
	if handle := exec.storeConn(client); handle == 0 {
		t.Fatal("store existing connection")
	}

	got, _ := callPluginHostGRPCUnary(t, exec, mod, grpcTestRequest([]byte("req")), grpcTestResponseLen)
	if got != pluginErrDenied {
		t.Fatalf("hostGRPCUnary() = %d, want %d", got, pluginErrDenied)
	}
	if _, dials := srv.observed(); len(dials) != 0 {
		t.Fatalf("dials = %#v, want none", dials)
	}
}
