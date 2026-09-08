//go:build !tinygo

package sdk

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LocalHTTPHandler emulates the agent's host-mediated HTTP operation during a
// source-native plugin run. Credential handling belongs in this trusted host
// callback, not in plugin config or plugin logic.
type LocalHTTPHandler func(context.Context, HTTPRequest) (*HTTPResponse, error)

// LocalHostOptions configures one source-native plugin execution.
type LocalHostOptions struct {
	ConfigJSON  []byte
	HTTPHandler LocalHTTPHandler
}

// LocalHostLog is one log message captured during a local run.
type LocalHostLog struct {
	Level   uint32
	Message string
}

// LocalHostCapture contains copied host outputs from a local run.
type LocalHostCapture struct {
	ResultJSON    []byte
	TelemetryJSON [][]byte
	Logs          []LocalHostLog
}

type localHostExecution struct {
	mu            sync.Mutex
	configJSON    []byte
	httpHandler   LocalHTTPHandler
	resultJSON    []byte
	telemetryJSON [][]byte
	logs          []LocalHostLog
}

var (
	localHostRunMu sync.Mutex
	localHostMu    sync.RWMutex
	localHost      *localHostExecution
)

// RunLocalHost installs a native development host for the duration of run.
// Local runs are process-scoped and serialized because the Wasm host ABI is
// process-global. Production package admission and signature checks are not
// emulated by this helper.
func RunLocalHost(options LocalHostOptions, run func() error) (LocalHostCapture, error) {
	if run == nil {
		return LocalHostCapture{}, errors.New("local host run function is required")
	}
	if len(options.ConfigJSON) > MaxPayloadBytes {
		return LocalHostCapture{}, errors.New("local host config exceeds the SDK payload limit")
	}

	localHostRunMu.Lock()
	defer localHostRunMu.Unlock()

	execution := &localHostExecution{
		configJSON:  append([]byte(nil), options.ConfigJSON...),
		httpHandler: options.HTTPHandler,
	}
	localHostMu.Lock()
	previous := localHost
	localHost = execution
	localHostMu.Unlock()
	defer func() {
		localHostMu.Lock()
		localHost = previous
		localHostMu.Unlock()
	}()

	runErr := run()
	return execution.capture(), runErr
}

func currentLocalHost() *localHostExecution {
	localHostMu.RLock()
	defer localHostMu.RUnlock()
	return localHost
}

func (h *localHostExecution) getConfig(buf []byte) int32 {
	if h == nil {
		return hostErrNotFound
	}
	if len(h.configJSON) > len(buf) {
		return hostErrTooLarge
	}
	copy(buf, h.configJSON)
	return int32(len(h.configJSON))
}

func (h *localHostExecution) log(level uint32, data []byte) {
	if h == nil || len(data) == 0 {
		return
	}
	h.mu.Lock()
	h.logs = append(h.logs, LocalHostLog{Level: level, Message: string(append([]byte(nil), data...))})
	h.mu.Unlock()
}

func (h *localHostExecution) submitResult(payload []byte) int32 {
	if h == nil || len(payload) == 0 {
		return hostErrInvalid
	}
	if len(payload) > MaxPayloadBytes {
		return hostErrTooLarge
	}
	h.mu.Lock()
	h.resultJSON = append(h.resultJSON[:0], payload...)
	h.mu.Unlock()
	return hostErrOK
}

func (h *localHostExecution) emitTelemetry(payload []byte) int32 {
	if h == nil || len(payload) == 0 {
		return hostErrInvalid
	}
	if len(payload) > MaxPayloadBytes {
		return hostErrTooLarge
	}
	h.mu.Lock()
	h.telemetryJSON = append(h.telemetryJSON, append([]byte(nil), payload...))
	h.mu.Unlock()
	return hostErrOK
}

func (h *localHostExecution) httpRequest(encoded, responseBuf []byte) int32 {
	if h == nil || h.httpHandler == nil {
		return hostErrNotFound
	}

	request, responseMode, err := decodeLocalHTTPRequest(encoded)
	if err != nil {
		return hostErrInvalid
	}

	ctx := context.Background()
	cancel := func() {}
	if request.TimeoutMS > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(request.TimeoutMS)*time.Millisecond)
	}
	defer cancel()

	response, err := h.httpHandler(ctx, request)
	if err != nil || response == nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return hostErrTimeout
		}
		return hostErrInternal
	}

	encodedResponse, err := encodeLocalHTTPResponse(responseMode, response)
	if err != nil {
		return hostErrInternal
	}
	if len(encodedResponse) > len(responseBuf) {
		return hostErrTooLarge
	}
	copy(responseBuf, encodedResponse)
	return int32(len(encodedResponse))
}

func (h *localHostExecution) capture() LocalHostCapture {
	h.mu.Lock()
	defer h.mu.Unlock()

	capture := LocalHostCapture{
		ResultJSON: append([]byte(nil), h.resultJSON...),
		Logs:       append([]LocalHostLog(nil), h.logs...),
	}
	for _, payload := range h.telemetryJSON {
		capture.TelemetryJSON = append(capture.TelemetryJSON, append([]byte(nil), payload...))
	}
	return capture
}

func decodeLocalHTTPRequest(encoded []byte) (HTTPRequest, string, error) {
	var payload httpRequestPayload
	if err := json.Unmarshal(encoded, &payload); err != nil {
		return HTTPRequest{}, "", err
	}
	if strings.TrimSpace(payload.URL) == "" || (payload.Body != "" && payload.BodyBase64 != "") {
		return HTTPRequest{}, "", errors.New("invalid local HTTP request")
	}

	body := []byte(payload.Body)
	if payload.BodyBase64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(payload.BodyBase64)
		if err != nil {
			return HTTPRequest{}, "", err
		}
		body = decoded
	}

	return HTTPRequest{
		Method:             payload.Method,
		URL:                payload.URL,
		Headers:            payload.Headers,
		Body:               body,
		BodyBase64:         payload.BodyBase64 != "",
		ResponseMode:       payload.ResponseMode,
		TimeoutMS:          payload.TimeoutMS,
		InsecureSkipVerify: payload.InsecureSkipVerify,
	}, payload.ResponseMode, nil
}

func encodeLocalHTTPResponse(mode string, response *HTTPResponse) ([]byte, error) {
	if strings.EqualFold(strings.TrimSpace(mode), "status_body") || strings.TrimSpace(mode) == "" {
		return append([]byte(strconv.Itoa(response.Status)+"\n"), response.Body...), nil
	}
	return json.Marshal(httpResponsePayload{
		Status:       response.Status,
		Headers:      response.Headers,
		BodyBase64:   base64.StdEncoding.EncodeToString(response.Body),
		BodyEncoding: "base64",
	})
}
