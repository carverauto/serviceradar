/*
 * Copyright 2025 Carver Automation Corporation.
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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/tetratelabs/wazero/api"
)

const (
	websocketReadLimitExceeded = "websocket: read limit exceeded"
	webSocketSecureScheme      = "wss"
)

var (
	errProxmoxConsoleWebSocketDialTimeout = errors.New("proxmox console WebSocket dial timed out")
	errProxmoxConsoleWebSocketDialFailed  = errors.New("proxmox console WebSocket dial failed")
)

type pluginWebSocketDialer func(
	context.Context,
	string,
	http.Header,
	time.Duration,
	bool,
) (*websocket.Conn, *http.Response, error)

func (e *pluginExecution) hostTCPConnect(ctx context.Context, mod api.Module, addrPtr, addrLen, port, timeoutMS uint32) int32 {
	if !e.hasCapability("tcp_connect") {
		return pluginErrDenied
	}

	addrBytes, ok := readMemory(mod, addrPtr, addrLen)
	if !ok {
		return pluginErrInvalid
	}
	host := strings.TrimSpace(string(addrBytes))
	if host == "" {
		return pluginErrInvalid
	}

	if !e.assignment.Permissions.allowsPort(int(port)) {
		return pluginErrDenied
	}

	ip, allowed := e.resolveAllowedAddr(ctx, host)
	if !allowed {
		return pluginErrDenied
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}

	dialer := net.Dialer{Timeout: timeout}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip.String(), fmt.Sprintf("%d", port)))
	if err != nil {
		return pluginErrInternal
	}

	handle := e.storeConn(conn)
	if handle == 0 {
		_ = conn.Close()
		return pluginErrTooLarge
	}

	return int32(handle)
}

func (e *pluginExecution) hostTCPRead(_ context.Context, mod api.Module, handle, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("tcp_read") {
		return pluginErrDenied
	}

	conn := e.getConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))

	if bufLen == 0 {
		return pluginErrInvalid
	}

	readBuf := make([]byte, bufLen)
	n, err := conn.Read(readBuf)
	if err != nil && !errors.Is(err, io.EOF) {
		return pluginErrInternal
	}

	if n == 0 {
		return pluginErrOK
	}

	if !writeMemory(mod, bufPtr, readBuf[:n]) {
		return pluginErrInvalid
	}

	return int32(n)
}

func (e *pluginExecution) hostTCPWrite(_ context.Context, mod api.Module, handle, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("tcp_write") {
		return pluginErrDenied
	}

	conn := e.getConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}

	data, ok := readMemory(mod, bufPtr, bufLen)
	if !ok {
		return pluginErrInvalid
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))

	n, err := conn.Write(data)
	if err != nil {
		return pluginErrInternal
	}
	return int32(n)
}

func (e *pluginExecution) hostTCPClose(_ context.Context, _ api.Module, handle uint32) int32 {
	if !e.hasCapability("tcp_close") {
		return pluginErrDenied
	}

	conn := e.deleteConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}
	_ = conn.Close()
	return pluginErrOK
}

func (e *pluginExecution) hostUDPSendTo(ctx context.Context, mod api.Module, addrPtr, addrLen, port, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("udp_sendto") {
		return pluginErrDenied
	}

	addrBytes, ok := readMemory(mod, addrPtr, addrLen)
	if !ok {
		return pluginErrInvalid
	}
	host := strings.TrimSpace(string(addrBytes))
	if host == "" {
		return pluginErrInvalid
	}

	if !e.assignment.Permissions.allowsPort(int(port)) {
		return pluginErrDenied
	}

	ip, allowed := e.resolveAllowedAddr(ctx, host)
	if !allowed {
		return pluginErrDenied
	}

	payload, ok := readMemory(mod, bufPtr, bufLen)
	if !ok {
		return pluginErrInvalid
	}

	raddr := &net.UDPAddr{IP: net.ParseIP(ip.String()), Port: int(port)}
	conn, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		return pluginErrInternal
	}
	defer func() {
		_ = conn.Close()
	}()

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))

	n, err := conn.Write(payload)
	if err != nil {
		return pluginErrInternal
	}

	return int32(n)
}

func (e *pluginExecution) hasCapability(capability string) bool {
	if e.assignment.Capabilities == nil {
		return false
	}
	return e.assignment.Capabilities[capability]
}

func (e *pluginExecution) resolveAllowedAddr(ctx context.Context, host string) (netip.Addr, bool) {
	addr, err := netip.ParseAddr(host)
	if err == nil {
		return addr, e.assignment.Permissions.allowsAddress(addr)
	}

	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil || len(addrs) == 0 {
		return netip.Addr{}, false
	}

	for _, candidate := range addrs {
		if addr, ok := netip.AddrFromSlice(candidate.IP); ok {
			if e.assignment.Permissions.allowsAddress(addr) {
				return addr, true
			}
		}
	}

	return netip.Addr{}, false
}

func (e *pluginExecution) storeConn(conn net.Conn) uint32 {
	e.mu.Lock()
	defer e.mu.Unlock()

	max := e.assignment.Resources.MaxOpenConnections
	if max > 0 && len(e.conns) >= max {
		return 0
	}

	if !e.manager.reserveConnection() {
		return 0
	}

	handle := e.nextHandle
	e.nextHandle++
	e.conns[handle] = conn
	return handle
}

func (e *pluginExecution) getConn(handle uint32) net.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.conns[handle]
}

func (e *pluginExecution) deleteConn(handle uint32) net.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	conn := e.conns[handle]
	delete(e.conns, handle)
	if conn != nil {
		e.manager.releaseConnection()
	}
	return conn
}

func (e *pluginExecution) closeAll() {
	e.mu.Lock()
	defer e.mu.Unlock()
	clearProxmoxConsoleTicketState(e.proxmoxConsoleTicket)
	e.proxmoxConsoleTicket = nil
	for handle, conn := range e.conns {
		_ = conn.Close()
		delete(e.conns, handle)
		e.manager.releaseConnection()
	}
	for handle, wsConn := range e.wsConns {
		_ = wsConn.Close()
		delete(e.wsConns, handle)
		e.manager.releaseConnection()
	}
	for handle, stream := range e.artifactStreams {
		_ = stream.abort()
		delete(e.artifactStreams, handle)
	}
	if e.mediaBridge != nil {
		e.mediaBridge.finish(io.EOF)
	}
}

func (e *pluginExecution) storeWSConn(conn *websocket.Conn) uint32 {
	e.mu.Lock()
	defer e.mu.Unlock()

	max := e.assignment.Resources.MaxOpenConnections
	totalConns := len(e.conns) + len(e.wsConns)
	if max > 0 && totalConns >= max {
		return 0
	}

	if !e.manager.reserveConnection() {
		return 0
	}

	handle := e.nextHandle
	e.nextHandle++
	e.wsConns[handle] = conn
	return handle
}

func (e *pluginExecution) getWSConn(handle uint32) *websocket.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.wsConns[handle]
}

func (e *pluginExecution) deleteWSConn(handle uint32) *websocket.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	conn := e.wsConns[handle]
	delete(e.wsConns, handle)
	if conn != nil {
		e.manager.releaseConnection()
	}
	return conn
}

func (e *pluginExecution) hostWebSocketConnect(ctx context.Context, mod api.Module, urlPtr, urlLen, timeoutMS uint32) int32 {
	if !e.hasCapability("websocket_connect") {
		return pluginErrDenied
	}

	urlBytes, ok := readMemory(mod, urlPtr, urlLen)
	if !ok {
		return pluginErrInvalid
	}
	wsURL, headers, insecureSkipVerify, parseErr := parseWebSocketConnectPayload(urlBytes)
	if parseErr != nil {
		return pluginErrInvalid
	}
	if wsURL == "" {
		return pluginErrInvalid
	}

	parsed, err := url.Parse(wsURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "ws" && parsed.Scheme != webSocketSecureScheme) {
		return pluginErrInvalid
	}

	proxmoxBinding, err := e.proxmoxHostAuthorityForWebSocket(parsed, headers, insecureSkipVerify)
	if err != nil {
		return pluginErrDenied
	}

	httpURL := *parsed
	if parsed.Scheme == webSocketSecureScheme {
		httpURL.Scheme = httpsScheme
	} else {
		httpURL.Scheme = httpScheme
	}
	port, validPort := pluginHTTPRequestPort(&httpURL)
	if !validPort || !e.assignment.Permissions.allowsHTTPPort(port) {
		return pluginErrDenied
	}
	if !e.assignment.Permissions.allowsHTTPHost(parsed.Hostname()) &&
		!pluginHostAuthorityDestinationAllowed(&e.assignment.Permissions, &httpURL, proxmoxBinding) {
		return pluginErrDenied
	}
	if err := e.applyProxmoxHostAuthorityWebSocketCredential(ctx, headers, proxmoxBinding); err != nil {
		return pluginErrDenied
	}
	if proxmoxBinding != nil {
		dialURL, consumeErr := e.consumeProxmoxConsoleTicket(parsed, proxmoxBinding)
		if consumeErr != nil {
			return pluginErrDenied
		}
		wsURL = dialURL.String()
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}

	dialCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if proxmoxBinding != nil {
		if err := e.ensureActiveProxmoxAssignment(dialCtx); err != nil {
			return pluginErrDenied
		}
	}

	conn, resp, err := e.dialPluginWebSocket(
		dialCtx,
		wsURL,
		headers,
		timeout,
		insecureSkipVerify,
	)
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			logErr := err
			if proxmoxBinding != nil {
				logErr = errProxmoxConsoleWebSocketDialTimeout
			}
			e.logPluginHostWebSocketFailure(logErr, parsed, "timeout")
			return pluginErrTimeout
		}
		logErr := err
		if proxmoxBinding != nil {
			logErr = errProxmoxConsoleWebSocketDialFailed
		}
		e.logPluginHostWebSocketFailure(logErr, parsed, "connect_failed")
		return pluginErrInternal
	}

	handle := e.storeWSConn(conn)
	if handle == 0 {
		_ = conn.Close()
		return pluginErrTooLarge
	}

	return int32(handle)
}

func (e *pluginExecution) dialPluginWebSocket(
	ctx context.Context,
	wsURL string,
	headers http.Header,
	timeout time.Duration,
	insecureSkipVerify bool,
) (*websocket.Conn, *http.Response, error) {
	if e != nil && e.webSocketDialer != nil {
		return e.webSocketDialer(ctx, wsURL, headers, timeout, insecureSkipVerify)
	}

	dialer := websocket.Dialer{HandshakeTimeout: timeout}
	if insecureSkipVerify {
		dialer.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec
	}
	return dialer.DialContext(ctx, wsURL, headers)
}

func (e *pluginExecution) logPluginHostWebSocketFailure(err error, wsURL *url.URL, reason string) {
	if e == nil || e.manager == nil || err == nil || wsURL == nil {
		return
	}

	e.manager.logger.Warn().
		Err(err).
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Str("scheme", wsURL.Scheme).
		Str("host", wsURL.Hostname()).
		Str("reason", reason).
		Msg("Plugin host WebSocket connection failed")
}

type websocketConnectPayload struct {
	URL                string            `json:"url"`
	Headers            map[string]string `json:"headers,omitempty"`
	InsecureSkipVerify bool              `json:"insecure_skip_verify,omitempty"`
}

func parseWebSocketConnectPayload(raw []byte) (string, http.Header, bool, error) {
	payload := strings.TrimSpace(string(raw))
	if payload == "" {
		return "", nil, false, errInvalidPath
	}

	// Backward-compatible mode: payload is just a URL string.
	if !strings.HasPrefix(payload, "{") {
		return payload, nil, false, nil
	}

	var parsed websocketConnectPayload
	if err := json.Unmarshal([]byte(payload), &parsed); err != nil {
		return "", nil, false, err
	}

	wsURL := strings.TrimSpace(parsed.URL)
	if wsURL == "" {
		return "", nil, false, errInvalidPath
	}

	if len(parsed.Headers) == 0 {
		return wsURL, nil, parsed.InsecureSkipVerify, nil
	}

	headers := make(http.Header, len(parsed.Headers))
	for key, value := range parsed.Headers {
		trimmedKey := strings.TrimSpace(key)
		if trimmedKey == "" {
			continue
		}
		headers.Set(trimmedKey, value)
	}

	if len(headers) == 0 {
		return wsURL, nil, parsed.InsecureSkipVerify, nil
	}
	return wsURL, headers, parsed.InsecureSkipVerify, nil
}

func (e *pluginExecution) hostWebSocketSend(_ context.Context, mod api.Module, handle, dataPtr, dataLen, timeoutMS uint32) int32 {
	if !e.hasCapability("websocket_send") {
		return pluginErrDenied
	}

	conn := e.getWSConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}

	data, ok := readMemory(mod, dataPtr, dataLen)
	if !ok {
		return pluginErrInvalid
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))

	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return pluginErrTimeout
		}
		return pluginErrInternal
	}

	return int32(len(data))
}

func (e *pluginExecution) hostWebSocketRecv(_ context.Context, mod api.Module, handle, bufPtr, bufLen, timeoutMS uint32) int32 {
	if !e.hasCapability("websocket_recv") {
		return pluginErrDenied
	}

	conn := e.getWSConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = e.assignment.Timeout
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	conn.SetReadLimit(pluginWebSocketReadLimit(bufLen))

	_, data, err := conn.ReadMessage()
	if err != nil {
		if strings.Contains(err.Error(), websocketReadLimitExceeded) {
			return pluginErrTooLarge
		}
		if errors.Is(err, context.DeadlineExceeded) || websocket.IsCloseError(err, websocket.CloseNormalClosure) {
			return pluginErrTimeout
		}
		return pluginErrInternal
	}

	if uint32(len(data)) > bufLen {
		return pluginErrTooLarge
	}

	if !writeMemory(mod, bufPtr, data) {
		return pluginErrInvalid
	}

	return int32(len(data))
}

func pluginWebSocketReadLimit(bufLen uint32) int64 {
	limit := int64(bufLen)
	if limit <= 0 || limit > pluginMaxPayloadBytes {
		return pluginMaxPayloadBytes
	}
	return limit
}

func (e *pluginExecution) hostWebSocketClose(_ context.Context, _ api.Module, handle uint32) int32 {
	if !e.hasCapability("websocket_close") {
		return pluginErrDenied
	}

	conn := e.deleteWSConn(handle)
	if conn == nil {
		return pluginErrBadHandle
	}
	_ = conn.Close()
	return pluginErrOK
}
