package sdk

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

var errWebSocketConnNotInitialized = errors.New("websocket connection not initialized")
var errWebSocketNotInitialized = errWebSocketConnNotInitialized

// WebSocketDialRequest defines a WebSocket connection request for the host proxy.
type WebSocketDialRequest struct {
	URL                string            `json:"url"`
	Headers            map[string]string `json:"headers,omitempty"`
	InsecureSkipVerify bool              `json:"insecure_skip_verify,omitempty"`
}

// WebSocketConn wraps a host WebSocket connection handle.
type WebSocketConn struct {
	handle uint32
}

// WebSocketDial opens a WebSocket connection via the host proxy.
func WebSocketDial(rawURL string, timeout time.Duration) (*WebSocketConn, error) {
	return WebSocketDialContext(context.Background(), rawURL, timeout)
}

// WebSocketDialWithHeaders opens a WebSocket connection via the host proxy with request headers.
func WebSocketDialWithHeaders(rawURL string, headers map[string]string, timeout time.Duration) (*WebSocketConn, error) {
	return WebSocketDialWithHeadersContext(context.Background(), rawURL, headers, timeout)
}

// WebSocketDialContext opens a WebSocket connection via the host proxy with a context.
func WebSocketDialContext(ctx context.Context, rawURL string, timeout time.Duration) (*WebSocketConn, error) {
	return WebSocketDialRequestContext(ctx, WebSocketDialRequest{URL: rawURL}, timeout)
}

// WebSocketDialWithHeadersContext opens a WebSocket connection via the host proxy with request headers and a context.
func WebSocketDialWithHeadersContext(
	ctx context.Context,
	rawURL string,
	headers map[string]string,
	timeout time.Duration,
) (*WebSocketConn, error) {
	return WebSocketDialRequestContext(ctx, WebSocketDialRequest{URL: rawURL, Headers: headers}, timeout)
}

// WebSocketConnect opens a WebSocket connection via the host proxy.
func WebSocketConnect(url string, timeout time.Duration) (*WebSocketConn, error) {
	return WebSocketDial(url, timeout)
}

// WebSocketConnectWithHeaders opens a WebSocket connection via the host proxy
// using optional request headers (for example Authorization).
func WebSocketConnectWithHeaders(url string, headers map[string]string, timeout time.Duration) (*WebSocketConn, error) {
	return WebSocketDialWithHeaders(url, headers, timeout)
}

// WebSocketConnectContext opens a WebSocket connection via the host proxy with a context.
func WebSocketConnectContext(ctx context.Context, url string, timeout time.Duration) (*WebSocketConn, error) {
	return WebSocketDialContext(ctx, url, timeout)
}

// WebSocketConnectContextWithHeaders opens a WebSocket connection via the host
// proxy with optional request headers and context.
func WebSocketConnectContextWithHeaders(
	ctx context.Context,
	url string,
	headers map[string]string,
	timeout time.Duration,
) (*WebSocketConn, error) {
	return WebSocketDialWithHeadersContext(ctx, url, headers, timeout)
}

// WebSocketDialRequestContext opens a WebSocket connection via the host proxy from a structured request.
func WebSocketDialRequestContext(ctx context.Context, req WebSocketDialRequest, timeout time.Duration) (*WebSocketConn, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	data, err := encodeWebSocketDialRequest(req)
	if err != nil {
		return nil, err
	}

	res := hostWebSocketConnect(ptrFromBytes(data), uint32(len(data)), uint32(timeout.Milliseconds()))
	if res < 0 {
		return nil, hostErr(res, "websocket_connect")
	}

	return &WebSocketConn{handle: uint32(res)}, nil
}

func encodeWebSocketDialRequest(req WebSocketDialRequest) ([]byte, error) {
	rawURL := strings.TrimSpace(req.URL)
	if len(req.Headers) == 0 && !req.InsecureSkipVerify {
		return []byte(rawURL), nil
	}

	payload := WebSocketDialRequest{
		URL:                rawURL,
		InsecureSkipVerify: req.InsecureSkipVerify,
	}
	if len(req.Headers) > 0 {
		payload.Headers = make(map[string]string, len(req.Headers))
		for key, value := range req.Headers {
			trimmedKey := strings.TrimSpace(key)
			trimmedValue := strings.TrimSpace(value)
			if trimmedKey == "" || trimmedValue == "" {
				continue
			}
			payload.Headers[trimmedKey] = trimmedValue
		}
	}
	if len(payload.Headers) == 0 && !payload.InsecureSkipVerify {
		return []byte(rawURL), nil
	}

	return json.Marshal(payload)
}

func encodeWebSocketConnectPayload(url string, headers map[string]string) ([]byte, error) {
	return encodeWebSocketDialRequest(WebSocketDialRequest{URL: url, Headers: headers})
}

// Send sends data through the WebSocket connection.
func (ws *WebSocketConn) Send(data []byte, timeout time.Duration) error {
	return ws.SendContext(context.Background(), data, timeout)
}

// SendContext sends data through the WebSocket connection with a context.
func (ws *WebSocketConn) SendContext(ctx context.Context, data []byte, timeout time.Duration) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}

	if ws == nil || ws.handle == 0 {
		return errWebSocketNotInitialized
	}
	if len(data) == 0 {
		return nil
	}

	res := hostWebSocketSend(ws.handle, ptrFromBytes(data), uint32(len(data)), uint32(timeout.Milliseconds()))
	if res < 0 {
		return hostErr(res, "websocket_send")
	}

	return nil
}

// Recv receives data from the WebSocket connection into buf.
func (ws *WebSocketConn) Recv(buf []byte, timeout time.Duration) (int, error) {
	return ws.RecvContext(context.Background(), buf, timeout)
}

// RecvContext receives data from the WebSocket connection into buf with a context.
func (ws *WebSocketConn) RecvContext(ctx context.Context, buf []byte, timeout time.Duration) (int, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
	}

	if ws == nil || ws.handle == 0 {
		return 0, errWebSocketNotInitialized
	}
	if len(buf) == 0 {
		return 0, nil
	}

	res := hostWebSocketRecv(ws.handle, ptrFromBytes(buf), uint32(len(buf)), uint32(timeout.Milliseconds()))
	if res < 0 {
		return 0, hostErr(res, "websocket_recv")
	}

	return int(res), nil
}

// Close closes the WebSocket connection.
func (ws *WebSocketConn) Close() error {
	if ws == nil || ws.handle == 0 {
		return nil
	}

	res := hostWebSocketClose(ws.handle)
	ws.handle = 0

	return hostErr(res, "websocket_close")
}
