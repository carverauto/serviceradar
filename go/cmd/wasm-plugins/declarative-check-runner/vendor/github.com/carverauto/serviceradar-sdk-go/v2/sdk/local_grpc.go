//go:build !tinygo

package sdk

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// LocalGRPCHandler emulates the agent's host-mediated grpc_unary operation
// during a source-native plugin run. The request has already passed the same
// shape and metadata checks the agent applies. Return a response with a
// non-OK Status to emulate a server-side gRPC error; return an error to emulate
// a transport failure, which the plugin sees as UNAVAILABLE.
type LocalGRPCHandler func(context.Context, GRPCRequest) (GRPCResponse, error)

const localGRPCDefaultTimeout = 10 * time.Second

// localGRPCReservedMetadata mirrors the host: transport-owned headers cannot be
// set from plugin metadata.
//
//nolint:gochecknoglobals
var localGRPCReservedMetadata = map[string]struct{}{
	"connection":        {},
	"content-type":      {},
	"host":              {},
	"keep-alive":        {},
	"proxy-connection":  {},
	"te":                {},
	"transfer-encoding": {},
	"upgrade":           {},
}

func (h *localHostExecution) grpcUnary(encoded, responseBuf []byte) int32 {
	if h == nil || h.grpcHandler == nil {
		return hostErrNotFound
	}

	request, err := decodeLocalGRPCRequest(encoded)
	if err != nil {
		return hostErrInvalid
	}

	timeout := localGRPCDefaultTimeout
	if request.TimeoutMS > 0 {
		timeout = time.Duration(request.TimeoutMS) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	response, err := h.grpcHandler(ctx, request)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return hostErrTimeout
		}
		// Handler errors can carry local secrets; report the class only, the
		// way the agent reports a dial failure.
		response = GRPCResponse{Status: GRPCCodeUnavailable, StatusMessage: "local grpc handler failed"}
	}

	limit := MaxGRPCResponseBytes
	if request.MaxResponseBytes > 0 && request.MaxResponseBytes < limit {
		limit = request.MaxResponseBytes
	}
	if len(response.Message) > limit {
		return hostErrTooLarge
	}

	encodedResponse, err := json.Marshal(grpcResponsePayload{
		GRPCStatus:    int32(response.Status),
		GRPCMessage:   response.StatusMessage,
		Headers:       response.Headers,
		Trailers:      response.Trailers,
		MessageBase64: base64.StdEncoding.EncodeToString(response.Message),
	})
	if err != nil {
		return hostErrInternal
	}
	if len(encodedResponse) > len(responseBuf) {
		return hostErrTooLarge
	}
	copy(responseBuf, encodedResponse)
	return int32(len(encodedResponse))
}

func decodeLocalGRPCRequest(encoded []byte) (GRPCRequest, error) {
	var payload grpcRequestPayload
	if err := json.Unmarshal(encoded, &payload); err != nil {
		return GRPCRequest{}, err
	}
	message, err := base64.StdEncoding.DecodeString(payload.MessageBase64)
	if err != nil {
		return GRPCRequest{}, err
	}
	metadata, err := normalizeLocalGRPCMetadata(payload.Metadata)
	if err != nil {
		return GRPCRequest{}, err
	}

	request := GRPCRequest{
		TargetHost:       payload.TargetHost,
		TargetPort:       payload.TargetPort,
		Authority:        payload.Authority,
		Method:           payload.Method,
		Metadata:         metadata,
		Message:          message,
		TimeoutMS:        payload.TimeoutMS,
		Transport:        payload.Transport,
		MaxResponseBytes: payload.MaxResponseBytes,
	}
	if payload.TLS != nil {
		request.TLS = &GRPCTLSConfig{
			ServerName:         payload.TLS.ServerName,
			InsecureSkipVerify: payload.TLS.InsecureSkipVerify,
		}
	}
	if request.TimeoutMS < 0 || request.MaxResponseBytes < 0 {
		return GRPCRequest{}, errors.New("invalid local grpc request bounds")
	}
	// Re-run the SDK's own shape checks: the local host must reject what the
	// agent rejects even if a caller bypasses GRPCClient.
	if _, err := newGRPCRequestPayload(request); err != nil {
		return GRPCRequest{}, err
	}
	if request.Transport != GRPCTransportTLS && request.Transport != GRPCTransportH2C {
		return GRPCRequest{}, errGRPCTransport
	}
	return request, nil
}

func normalizeLocalGRPCMetadata(metadata map[string]string) (map[string]string, error) {
	if len(metadata) == 0 {
		return nil, nil
	}
	normalized := make(map[string]string, len(metadata))
	for key, value := range metadata {
		name := strings.ToLower(strings.TrimSpace(key))
		if _, reserved := localGRPCReservedMetadata[name]; reserved ||
			name == "" || strings.HasPrefix(name, ":") || strings.HasPrefix(name, "grpc-") {
			return nil, errors.New("reserved grpc metadata key")
		}
		if _, duplicate := normalized[name]; duplicate {
			return nil, errors.New("duplicate grpc metadata key")
		}
		if strings.HasSuffix(name, "-bin") {
			if _, err := base64.StdEncoding.DecodeString(value); err != nil {
				return nil, errors.New("binary grpc metadata must be base64")
			}
		}
		normalized[name] = value
	}
	return normalized, nil
}
