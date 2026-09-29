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
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"github.com/tetratelabs/wazero/api"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// The grpc_unary host function performs one unary gRPC call on behalf of the
// guest. The guest supplies an already-serialized request message and receives
// the serialized response message; the host never interprets either, so no
// .proto definition is compiled into the agent. The request/response JSON and
// the negative return codes are a shared contract with the Go and Rust SDKs.

const (
	pluginGRPCTransportH2C = "h2c"
	pluginGRPCTransportTLS = "tls"

	pluginDefaultGRPCTimeout       = 10 * time.Second
	pluginMaxGRPCResponseBytes     = 4 * 1024 * 1024
	pluginMaxGRPCHeaderListBytes   = 64 * 1024
	pluginGRPCBinaryMetadataSuffix = "-bin"
)

const (
	pluginGRPCDeniedReasonCapacity = "max_open_connections"
	pluginGRPCDeniedReasonH2C      = "h2c_outside_allowed_networks"
)

var (
	errPluginGRPCFrameType = errors.New("grpc raw codec: unexpected message type")
	errPluginGRPCTLSTrust  = errors.New("plugin gRPC TLS trust configuration unavailable")
)

// Request-metadata keys the host owns. The HTTP/2 transport, content
// negotiation, deadline propagation and connection management are set by the
// host and must not be replaced or duplicated by guest metadata.
//
//nolint:gochecknoglobals
var pluginGRPCReservedMetadataKeys = map[string]struct{}{
	"connection":        {},
	"content-type":      {},
	"host":              {},
	"keep-alive":        {},
	"proxy-connection":  {},
	"te":                {},
	"transfer-encoding": {},
	"upgrade":           {},
	"user-agent":        {},
}

type grpcUnaryRequestPayload struct {
	TargetHost       string            `json:"target_host"`
	TargetPort       int               `json:"target_port"`
	Authority        string            `json:"authority"`
	Method           string            `json:"method"`
	Metadata         map[string]string `json:"metadata"`
	MessageBase64    string            `json:"message_base64"`
	TimeoutMS        int               `json:"timeout_ms"`
	Transport        string            `json:"transport"`
	TLS              *grpcUnaryTLS     `json:"tls,omitempty"`
	MaxResponseBytes int               `json:"max_response_bytes"`
}

type grpcUnaryTLS struct {
	ServerName         string `json:"server_name"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify"`
}

// Headers, trailers and message_base64 are always present so a strict decoder
// on the guest side never sees a missing or null field.
type grpcUnaryResponsePayload struct {
	GRPCStatus    int                 `json:"grpc_status"`
	GRPCMessage   string              `json:"grpc_message"`
	Headers       map[string][]string `json:"headers"`
	Trailers      map[string][]string `json:"trailers"`
	MessageBase64 string              `json:"message_base64"`
}

// grpcUnaryCall is a validated request. Nothing in it has been dialed yet.
type grpcUnaryCall struct {
	host             string
	hostAddr         netip.Addr
	hostIsIP         bool
	port             int
	authority        string
	method           string
	metadata         metadata.MD
	message          []byte
	timeout          time.Duration
	transport        string
	tlsServerName    string
	tlsSkipVerify    bool
	maxResponseBytes int
}

type pluginGRPCDialer func(ctx context.Context, addr string) (net.Conn, error)

// pluginGRPCRawCodec passes already-serialized messages through unchanged. Its
// name is "proto" so the call carries the standard application/grpc+proto
// content type that every protobuf gRPC server accepts.
type pluginGRPCRawCodec struct{}

func (pluginGRPCRawCodec) Marshal(v any) ([]byte, error) {
	frame, ok := v.(*[]byte)
	if !ok || frame == nil {
		return nil, errPluginGRPCFrameType
	}
	return *frame, nil
}

func (pluginGRPCRawCodec) Unmarshal(data []byte, v any) error {
	frame, ok := v.(*[]byte)
	if !ok || frame == nil {
		return errPluginGRPCFrameType
	}
	*frame = append((*frame)[:0], data...)
	return nil
}

func (pluginGRPCRawCodec) Name() string {
	return "proto"
}

func (e *pluginExecution) hostGRPCUnary(ctx context.Context, mod api.Module, reqPtr, reqLen, respPtr, respLen uint32) int32 {
	if !e.hasCapability(pluginCapabilityGRPCRequest) {
		return pluginErrDenied
	}

	reqBytes, ok := readMemory(mod, reqPtr, reqLen)
	if !ok {
		return pluginErrInvalid
	}
	if len(reqBytes) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	var payload grpcUnaryRequestPayload
	if err := json.Unmarshal(reqBytes, &payload); err != nil {
		return pluginErrInvalid
	}

	call, ok := parseGRPCUnaryRequest(payload)
	if !ok {
		return pluginErrInvalid
	}

	callCtx, cancel := context.WithTimeout(ctx, call.timeout)
	defer cancel()

	// The destination is checked exactly as http_request checks it, before any
	// resolution or dial.
	permissions := &e.assignment.Permissions
	if !permissions.allowsHTTPPort(call.port) {
		e.logPluginHostGRPCDenied(call, pluginHTTPDeniedReasonEgressPort)
		return pluginErrDenied
	}
	if !permissions.allowsHTTPHost(call.host) {
		e.logPluginHostGRPCDenied(call, pluginHTTPDeniedReasonEgressHost)
		return pluginErrDenied
	}

	dialAddr, code, unavailable := e.grpcDialAddress(callCtx, call)
	if code != pluginErrOK {
		return code
	}
	if unavailable != nil {
		return writeGRPCUnaryResponse(mod, respPtr, respLen, grpcUnaryUnavailableResponse(unavailable))
	}

	if !e.reserveTransientConnection() {
		e.logPluginHostGRPCDenied(call, pluginGRPCDeniedReasonCapacity)
		return pluginErrDenied
	}
	defer e.releaseTransientConnection()

	return e.invokeGRPCUnary(callCtx, mod, call, dialAddr, respPtr, respLen)
}

// grpcDialAddress returns the address to dial. A plaintext (h2c) call must land
// inside allowed_networks, so its hostname is resolved here and the call is
// pinned to the permitted address it resolved to; the dial can then not be
// redirected by a second lookup. A TLS call is dialed by name, as http_request
// dials, and the server certificate authenticates the destination.
//
// A lookup failure is a transport failure the guest sees as UNAVAILABLE, not a
// host error code.
func (e *pluginExecution) grpcDialAddress(ctx context.Context, call grpcUnaryCall) (string, int32, error) {
	port := strconv.Itoa(call.port)
	if call.transport != pluginGRPCTransportH2C {
		return net.JoinHostPort(call.host, port), pluginErrOK, nil
	}

	permissions := &e.assignment.Permissions
	if len(permissions.allowedPrefixes) == 0 {
		// No network can match, so refuse before any DNS lookup.
		e.logPluginHostGRPCDenied(call, pluginGRPCDeniedReasonH2C)
		return "", pluginErrDenied, nil
	}
	if call.hostIsIP {
		if !permissions.allowsAddress(call.hostAddr) && !permissions.allowsAddress(call.hostAddr.Unmap()) {
			e.logPluginHostGRPCDenied(call, pluginGRPCDeniedReasonH2C)
			return "", pluginErrDenied, nil
		}
		return net.JoinHostPort(call.hostAddr.String(), port), pluginErrOK, nil
	}

	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, call.host)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return "", pluginErrTimeout, nil
		}
		return "", pluginErrOK, err
	}
	for _, candidate := range addrs {
		addr, ok := netip.AddrFromSlice(candidate.IP)
		if !ok {
			continue
		}
		addr = addr.Unmap()
		if permissions.allowsAddress(addr) {
			return net.JoinHostPort(addr.String(), port), pluginErrOK, nil
		}
	}

	e.logPluginHostGRPCDenied(call, pluginGRPCDeniedReasonH2C)
	return "", pluginErrDenied, nil
}

func (e *pluginExecution) invokeGRPCUnary(
	ctx context.Context,
	mod api.Module,
	call grpcUnaryCall,
	dialAddr string,
	respPtr, respLen uint32,
) int32 {
	transportCreds, err := e.grpcTransportCredentials(call)
	if err != nil {
		e.logPluginHostGRPCFailure(err, call, "tls_trust_unavailable")
		return pluginErrInternal
	}

	authority := call.authority
	if authority == "" {
		authority = net.JoinHostPort(call.host, strconv.Itoa(call.port))
	}

	dialer := e.grpcDialer
	if dialer == nil {
		dialer = func(dialCtx context.Context, addr string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(dialCtx, "tcp", addr)
		}
	}

	// A custom context dialer also keeps grpc-go from routing through an
	// environment proxy, so the connection reaches the address checked above.
	conn, err := grpc.NewClient(
		"passthrough:///"+dialAddr,
		grpc.WithTransportCredentials(transportCreds),
		grpc.WithAuthority(authority),
		grpc.WithContextDialer(dialer),
		grpc.WithMaxHeaderListSize(pluginMaxGRPCHeaderListBytes),
		grpc.WithDisableServiceConfig(),
		grpc.WithDisableRetry(),
	)
	if err != nil {
		e.logPluginHostGRPCFailure(err, call, "client_setup_failed")
		return pluginErrInternal
	}
	defer func() {
		_ = conn.Close()
	}()

	callCtx := ctx
	if len(call.metadata) > 0 {
		callCtx = metadata.NewOutgoingContext(callCtx, call.metadata)
	}

	request := call.message
	var reply []byte
	var header, trailer metadata.MD
	invokeErr := conn.Invoke(
		callCtx,
		call.method,
		&request,
		&reply,
		grpc.ForceCodec(pluginGRPCRawCodec{}),
		grpc.MaxCallRecvMsgSize(call.maxResponseBytes),
		grpc.Header(&header),
		grpc.Trailer(&trailer),
	)
	defer clear(reply)

	response := grpcUnaryResponsePayload{
		Headers:  grpcMetadataToResponse(header),
		Trailers: grpcMetadataToResponse(trailer),
	}

	if invokeErr != nil {
		st := status.Convert(invokeErr)
		// The deadline travels to the server as grpc-timeout, so a server that
		// honors it can answer DEADLINE_EXCEEDED a moment before the local timer
		// fires. Both are the same timeout to the guest.
		if errors.Is(ctx.Err(), context.DeadlineExceeded) || st.Code() == codes.DeadlineExceeded {
			e.logPluginHostGRPCFailure(invokeErr, call, "timeout")
			return pluginErrTimeout
		}
		if ctx.Err() != nil {
			e.logPluginHostGRPCFailure(invokeErr, call, "canceled")
			return pluginErrInternal
		}
		if grpcResponseExceededReceiveLimit(st) {
			return pluginErrTooLarge
		}
		response.GRPCStatus = int(st.Code())
		response.GRPCMessage = st.Message()
		return writeGRPCUnaryResponse(mod, respPtr, respLen, response)
	}

	if len(reply) > call.maxResponseBytes {
		return pluginErrTooLarge
	}
	response.GRPCStatus = int(codes.OK)
	response.MessageBase64 = base64.StdEncoding.EncodeToString(reply)

	return writeGRPCUnaryResponse(mod, respPtr, respLen, response)
}

// grpcResponseExceededReceiveLimit reports whether grpc-go refused the response
// message because it exceeded MaxCallRecvMsgSize. grpc-go reports that
// client-side as RESOURCE_EXHAUSTED with one of the messages below; a server
// that itself returns RESOURCE_EXHAUSTED carries its own message and is passed
// to the guest as a completed RPC.
func grpcResponseExceededReceiveLimit(st *status.Status) bool {
	if st == nil || st.Code() != codes.ResourceExhausted {
		return false
	}
	message := st.Message()
	return strings.HasPrefix(message, "grpc: received message larger than max") ||
		strings.HasPrefix(message, "grpc: received message after decompression larger than max") ||
		strings.HasPrefix(message, "grpc: message after decompression larger than max")
}

func grpcUnaryUnavailableResponse(err error) grpcUnaryResponsePayload {
	return grpcUnaryResponsePayload{
		GRPCStatus:  int(codes.Unavailable),
		GRPCMessage: err.Error(),
		Headers:     map[string][]string{},
		Trailers:    map[string][]string{},
	}
}

func writeGRPCUnaryResponse(mod api.Module, respPtr, respLen uint32, response grpcUnaryResponsePayload) int32 {
	responseBytes, err := json.Marshal(response)
	if err != nil {
		return pluginErrInternal
	}
	if len(responseBytes) > int(respLen) {
		return pluginErrTooLarge
	}
	if !writeMemory(mod, respPtr, responseBytes) {
		return pluginErrInvalid
	}
	return int32(len(responseBytes))
}

// grpcMetadataToResponse copies received metadata for the guest. Binary
// (-bin) values arrive decoded from grpc-go and are re-encoded as base64.
func grpcMetadataToResponse(md metadata.MD) map[string][]string {
	out := make(map[string][]string, len(md))
	for key, values := range md {
		copied := make([]string, 0, len(values))
		binary := strings.HasSuffix(key, pluginGRPCBinaryMetadataSuffix)
		for _, value := range values {
			if binary {
				value = base64.StdEncoding.EncodeToString([]byte(value))
			}
			copied = append(copied, value)
		}
		out[key] = copied
	}
	return out
}

// grpcTransportCredentials builds h2c or TLS credentials. TLS verifies against
// the same roots the host uses for plugin HTTPS, so an operator-configured CA
// applies to both, and a trust configuration that failed to load fails closed
// here as it does for HTTP.
func (e *pluginExecution) grpcTransportCredentials(call grpcUnaryCall) (credentials.TransportCredentials, error) {
	if call.transport == pluginGRPCTransportH2C {
		return insecure.NewCredentials(), nil
	}

	roots, err := e.pluginGRPCTLSRoots()
	if err != nil {
		return nil, err
	}

	tlsConfig := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		RootCAs:            roots,
		ServerName:         call.tlsServerName,
		InsecureSkipVerify: call.tlsSkipVerify, //nolint:gosec // explicit per-call guest opt-in, as for http_request
	}

	return credentials.NewTLS(tlsConfig), nil
}

func (e *pluginExecution) pluginGRPCTLSRoots() (*x509.CertPool, error) {
	if e == nil || e.manager == nil || e.manager.httpClient == nil {
		return nil, nil
	}

	switch transport := e.manager.httpClient.Transport.(type) {
	case *http.Transport:
		if transport != nil && transport.TLSClientConfig != nil {
			return transport.TLSClientConfig.RootCAs, nil
		}
	case unavailablePluginHTTPTransport:
		if transport.err != nil {
			return nil, transport.err
		}
		return nil, errPluginGRPCTLSTrust
	}

	return nil, nil
}

// reserveTransientConnection counts a connection that lives only for one host
// call against max_open_connections and the engine-wide connection limit.
func (e *pluginExecution) reserveTransientConnection() bool {
	e.mu.Lock()
	defer e.mu.Unlock()

	limit := e.assignment.Resources.MaxOpenConnections
	if limit > 0 && len(e.conns)+len(e.wsConns)+e.transientConns >= limit {
		return false
	}
	if e.manager != nil && !e.manager.reserveConnection() {
		return false
	}
	e.transientConns++
	return true
}

func (e *pluginExecution) releaseTransientConnection() {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.transientConns > 0 {
		e.transientConns--
		if e.manager != nil {
			e.manager.releaseConnection()
		}
	}
}

func parseGRPCUnaryRequest(payload grpcUnaryRequestPayload) (grpcUnaryCall, bool) {
	call := grpcUnaryCall{}

	host := strings.TrimSpace(payload.TargetHost)
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = host[1 : len(host)-1]
	}
	host = strings.TrimSuffix(host, ".")
	if addr, err := netip.ParseAddr(host); err == nil {
		if addr.Zone() != "" {
			return call, false
		}
		call.hostAddr = addr
		call.hostIsIP = true
	} else if !validGRPCHostname(host) {
		return call, false
	}
	call.host = host

	if payload.TargetPort < 1 || payload.TargetPort > 65535 {
		return call, false
	}
	call.port = payload.TargetPort

	authority := strings.TrimSpace(payload.Authority)
	if authority != "" && !validGRPCAuthority(authority) {
		return call, false
	}
	call.authority = authority

	if !validGRPCMethod(payload.Method) {
		return call, false
	}
	call.method = payload.Method

	md, ok := parseGRPCRequestMetadata(payload.Metadata)
	if !ok {
		return call, false
	}
	call.metadata = md

	if payload.MessageBase64 != "" {
		message, err := base64.StdEncoding.DecodeString(payload.MessageBase64)
		if err != nil {
			return call, false
		}
		call.message = message
	}
	if call.message == nil {
		call.message = []byte{}
	}

	if payload.TimeoutMS < 0 {
		return call, false
	}
	call.timeout = pluginDefaultGRPCTimeout
	if payload.TimeoutMS > 0 {
		call.timeout = time.Duration(payload.TimeoutMS) * time.Millisecond
	}

	switch strings.ToLower(strings.TrimSpace(payload.Transport)) {
	case pluginGRPCTransportH2C:
		call.transport = pluginGRPCTransportH2C
	case pluginGRPCTransportTLS:
		call.transport = pluginGRPCTransportTLS
	default:
		return call, false
	}
	if payload.TLS != nil {
		serverName := strings.TrimSpace(payload.TLS.ServerName)
		if serverName != "" && !validGRPCHostname(serverName) {
			if _, err := netip.ParseAddr(serverName); err != nil {
				return call, false
			}
		}
		call.tlsServerName = serverName
		call.tlsSkipVerify = payload.TLS.InsecureSkipVerify
	}

	if payload.MaxResponseBytes < 0 {
		return call, false
	}
	call.maxResponseBytes = pluginMaxGRPCResponseBytes
	if payload.MaxResponseBytes > 0 && payload.MaxResponseBytes < call.maxResponseBytes {
		call.maxResponseBytes = payload.MaxResponseBytes
	}

	return call, true
}

// parseGRPCRequestMetadata lowercases keys and rejects anything the host owns:
// HTTP/2 pseudo-headers, grpc-* keys, and the reserved transport headers. Key
// characters follow the gRPC wire spec; -bin values are base64 and every other
// value must be printable ASCII.
func parseGRPCRequestMetadata(raw map[string]string) (metadata.MD, bool) {
	if len(raw) == 0 {
		return nil, true
	}

	md := make(metadata.MD, len(raw))
	for rawKey, value := range raw {
		key := strings.ToLower(strings.TrimSpace(rawKey))
		if key == "" || strings.HasPrefix(key, ":") || strings.HasPrefix(key, "grpc-") {
			return nil, false
		}
		if _, reserved := pluginGRPCReservedMetadataKeys[key]; reserved {
			return nil, false
		}
		if !validGRPCMetadataKey(key) {
			return nil, false
		}

		if strings.HasSuffix(key, pluginGRPCBinaryMetadataSuffix) {
			decoded, ok := decodeGRPCBinaryMetadata(value)
			if !ok {
				return nil, false
			}
			md.Append(key, string(decoded))
			continue
		}
		if !validGRPCMetadataValue(value) {
			return nil, false
		}
		md.Append(key, value)
	}

	return md, true
}

func decodeGRPCBinaryMetadata(value string) ([]byte, bool) {
	if decoded, err := base64.StdEncoding.DecodeString(value); err == nil {
		return decoded, true
	}
	if decoded, err := base64.RawStdEncoding.DecodeString(value); err == nil {
		return decoded, true
	}
	return nil, false
}

func validGRPCMetadataKey(key string) bool {
	for i := 0; i < len(key); i++ {
		c := key[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-', c == '_', c == '.':
		default:
			return false
		}
	}
	return true
}

func validGRPCMetadataValue(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] < 0x20 || value[i] > 0x7e {
			return false
		}
	}
	return true
}

// validGRPCMethod accepts only the "/package.Service/Method" form.
func validGRPCMethod(method string) bool {
	if !strings.HasPrefix(method, "/") {
		return false
	}
	parts := strings.Split(method[1:], "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	for i := 0; i < len(method); i++ {
		if method[i] <= 0x20 || method[i] >= 0x7f {
			return false
		}
	}
	return true
}

func validGRPCHostname(host string) bool {
	if host == "" || len(host) > 253 {
		return false
	}
	for i := 0; i < len(host); i++ {
		c := host[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '.', c == '_':
		default:
			return false
		}
	}
	return true
}

// validGRPCAuthority allows a host or host:port override of :authority. It
// changes only the header value; the destination is always target_host.
func validGRPCAuthority(authority string) bool {
	for i := 0; i < len(authority); i++ {
		c := authority[i]
		if c <= 0x20 || c >= 0x7f {
			return false
		}
		switch c {
		case '/', '@', '?', '#', '\\':
			return false
		}
	}
	return true
}

func (e *pluginExecution) logPluginHostGRPCDenied(call grpcUnaryCall, reason string) {
	if e == nil || e.manager == nil {
		return
	}

	e.manager.logger.Warn().
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Str("grpc_method", call.method).
		Str("transport", call.transport).
		Str("host", call.host).
		Int("port", call.port).
		Str("reason", reason).
		Msg("Plugin host gRPC request denied")
}

func (e *pluginExecution) logPluginHostGRPCFailure(err error, call grpcUnaryCall, reason string) {
	if e == nil || e.manager == nil || err == nil {
		return
	}

	e.manager.logger.Warn().
		Err(err).
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Str("grpc_method", call.method).
		Str("transport", call.transport).
		Str("host", call.host).
		Int("port", call.port).
		Str("reason", reason).
		Msg("Plugin host gRPC request failed")
}
