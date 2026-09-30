package sdk

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const (
	// CapabilityGRPCRequest is the manifest capability that grants the
	// grpc_unary host import.
	CapabilityGRPCRequest = "grpc_request"

	// GRPCTransportTLS dials the target over TLS. It is the SDK default.
	GRPCTransportTLS = "tls"
	// GRPCTransportH2C dials cleartext HTTP/2. The host only allows it when
	// the resolved destination is inside the manifest's allowed_networks.
	GRPCTransportH2C = "h2c"

	// MaxGRPCResponseBytes is the host cap on a serialized response message.
	MaxGRPCResponseBytes = 4 * 1024 * 1024

	// grpcResponseEnvelopeOverhead leaves room in the response buffer for
	// the JSON envelope, status message, headers and trailers.
	grpcResponseEnvelopeOverhead = 64 * 1024
)

// GRPCCode is a gRPC status code as defined by the gRPC protocol.
type GRPCCode int32

const (
	GRPCCodeOK                 GRPCCode = 0
	GRPCCodeCanceled           GRPCCode = 1
	GRPCCodeUnknown            GRPCCode = 2
	GRPCCodeInvalidArgument    GRPCCode = 3
	GRPCCodeDeadlineExceeded   GRPCCode = 4
	GRPCCodeNotFound           GRPCCode = 5
	GRPCCodeAlreadyExists      GRPCCode = 6
	GRPCCodePermissionDenied   GRPCCode = 7
	GRPCCodeResourceExhausted  GRPCCode = 8
	GRPCCodeFailedPrecondition GRPCCode = 9
	GRPCCodeAborted            GRPCCode = 10
	GRPCCodeOutOfRange         GRPCCode = 11
	GRPCCodeUnimplemented      GRPCCode = 12
	GRPCCodeInternal           GRPCCode = 13
	GRPCCodeUnavailable        GRPCCode = 14
	GRPCCodeDataLoss           GRPCCode = 15
	GRPCCodeUnauthenticated    GRPCCode = 16
)

//nolint:gochecknoglobals
var grpcCodeNames = [...]string{
	"OK", "CANCELED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED",
	"NOT_FOUND", "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED",
	"FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED",
	"INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED",
}

func (c GRPCCode) String() string {
	if c >= 0 && int(c) < len(grpcCodeNames) {
		return grpcCodeNames[c]
	}
	return fmt.Sprintf("CODE(%d)", int32(c))
}

var (
	errGRPCMissingTarget = errors.New("grpc request requires target_host")
	errGRPCInvalidPort   = errors.New("grpc request target_port must be between 1 and 65535")
	errGRPCInvalidMethod = errors.New("grpc request method must look like /package.Service/Method")
	errGRPCTransport     = errors.New("grpc request transport must be h2c or tls")
)

// GRPCTLSConfig tunes the TLS transport. It is ignored for h2c.
type GRPCTLSConfig struct {
	ServerName         string
	InsecureSkipVerify bool
}

// GRPCRequest is one host-proxied unary gRPC call. Message is the serialized
// request protobuf; the SDK does not depend on a protobuf runtime.
type GRPCRequest struct {
	TargetHost string
	TargetPort int
	// Authority overrides the :authority pseudo-header when set.
	Authority string
	// Method is the full method path, for example /example.v1.Device/Handle.
	Method string
	// Metadata keys are lowercased by the host. Reserved and grpc-* keys are
	// rejected; values for keys ending in -bin must be base64.
	Metadata  map[string]string
	Message   []byte
	TimeoutMS int
	// Transport is GRPCTransportTLS or GRPCTransportH2C. Empty uses TLS.
	Transport string
	TLS       *GRPCTLSConfig
	// MaxResponseBytes lowers the host response cap when set.
	MaxResponseBytes int
}

// GRPCResponse is a completed RPC. Status is set for every completed call,
// including non-OK ones.
type GRPCResponse struct {
	Status        GRPCCode
	StatusMessage string
	Headers       map[string][]string
	Trailers      map[string][]string
	Message       []byte
	Duration      time.Duration
}

// GRPCStatusError is returned by GRPCClient.Unary when the RPC completed with a
// non-OK status. Transport failures that never reached the server surface as
// GRPCCodeUnavailable.
type GRPCStatusError struct {
	Code     GRPCCode
	Message  string
	Trailers map[string][]string
}

func (e *GRPCStatusError) Error() string {
	if e.Message == "" {
		return "grpc status " + e.Code.String()
	}
	return "grpc status " + e.Code.String() + ": " + e.Message
}

type grpcTLSPayload struct {
	ServerName         string `json:"server_name,omitempty"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify"`
}

type grpcRequestPayload struct {
	TargetHost       string            `json:"target_host"`
	TargetPort       int               `json:"target_port"`
	Authority        string            `json:"authority,omitempty"`
	Method           string            `json:"method"`
	Metadata         map[string]string `json:"metadata,omitempty"`
	MessageBase64    string            `json:"message_base64"`
	TimeoutMS        int               `json:"timeout_ms,omitempty"`
	Transport        string            `json:"transport"`
	TLS              *grpcTLSPayload   `json:"tls,omitempty"`
	MaxResponseBytes int               `json:"max_response_bytes,omitempty"`
}

type grpcResponsePayload struct {
	GRPCStatus    int32               `json:"grpc_status"`
	GRPCMessage   string              `json:"grpc_message"`
	Headers       map[string][]string `json:"headers,omitempty"`
	Trailers      map[string][]string `json:"trailers,omitempty"`
	MessageBase64 string              `json:"message_base64"`
}

// GRPC provides host-proxied unary gRPC calls.
//
//nolint:gochecknoglobals
var GRPC = &GRPCClient{MaxResponseBytes: MaxGRPCResponseBytes}

// GRPCClient wraps the grpc_unary host call.
type GRPCClient struct {
	// MaxResponseBytes bounds the response message the client is prepared to
	// receive. The response buffer is sized for its base64 JSON envelope.
	MaxResponseBytes uint32
}

// Unary performs one unary RPC through the host. A non-OK status returns both
// the response (for headers and trailers) and a *GRPCStatusError. Host policy
// failures return a HostError.
func (c *GRPCClient) Unary(ctx context.Context, req GRPCRequest) (*GRPCResponse, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	payload, err := newGRPCRequestPayload(req)
	if err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	respBuf := make([]byte, c.responseBufferSize(req.MaxResponseBytes))
	start := time.Now()
	res := callHostGRPCUnary(encoded, respBuf)
	if err := hostErr(res, "grpc_unary"); err != nil {
		return nil, err
	}
	if uint32(res) > uint32(len(respBuf)) {
		return nil, HostError{Code: hostErrTooLarge, Op: "grpc_unary"}
	}

	return decodeGRPCResponse(respBuf[:res], time.Since(start))
}

func (c *GRPCClient) responseBufferSize(requestLimit int) int {
	limit := int(c.MaxResponseBytes)
	if limit <= 0 {
		limit = MaxGRPCResponseBytes
	}
	if requestLimit > 0 && requestLimit < limit {
		limit = requestLimit
	}
	return base64.StdEncoding.EncodedLen(limit) + grpcResponseEnvelopeOverhead
}

func newGRPCRequestPayload(req GRPCRequest) (grpcRequestPayload, error) {
	host := strings.TrimSpace(req.TargetHost)
	if host == "" {
		return grpcRequestPayload{}, errGRPCMissingTarget
	}
	if req.TargetPort < 1 || req.TargetPort > 65535 {
		return grpcRequestPayload{}, errGRPCInvalidPort
	}
	method := strings.TrimSpace(req.Method)
	if !validGRPCMethod(method) {
		return grpcRequestPayload{}, errGRPCInvalidMethod
	}
	transport := strings.ToLower(strings.TrimSpace(req.Transport))
	if transport == "" {
		transport = GRPCTransportTLS
	}
	if transport != GRPCTransportTLS && transport != GRPCTransportH2C {
		return grpcRequestPayload{}, errGRPCTransport
	}

	payload := grpcRequestPayload{
		TargetHost:       host,
		TargetPort:       req.TargetPort,
		Authority:        strings.TrimSpace(req.Authority),
		Method:           method,
		Metadata:         req.Metadata,
		MessageBase64:    base64.StdEncoding.EncodeToString(req.Message),
		TimeoutMS:        req.TimeoutMS,
		Transport:        transport,
		MaxResponseBytes: req.MaxResponseBytes,
	}
	if req.TLS != nil {
		payload.TLS = &grpcTLSPayload{
			ServerName:         req.TLS.ServerName,
			InsecureSkipVerify: req.TLS.InsecureSkipVerify,
		}
	}
	return payload, nil
}

// validGRPCMethod accepts /service/method with non-empty service and method.
func validGRPCMethod(method string) bool {
	if len(method) < 4 || method[0] != '/' {
		return false
	}
	service, name, ok := strings.Cut(method[1:], "/")
	return ok && service != "" && name != "" && !strings.Contains(name, "/")
}

func decodeGRPCResponse(payload []byte, duration time.Duration) (*GRPCResponse, error) {
	var decoded grpcResponsePayload
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, err
	}
	message, err := base64.StdEncoding.DecodeString(decoded.MessageBase64)
	if err != nil {
		return nil, err
	}

	response := &GRPCResponse{
		Status:        GRPCCode(decoded.GRPCStatus),
		StatusMessage: decoded.GRPCMessage,
		Headers:       decoded.Headers,
		Trailers:      decoded.Trailers,
		Message:       message,
		Duration:      duration,
	}
	if response.Status != GRPCCodeOK {
		return response, &GRPCStatusError{
			Code:     response.Status,
			Message:  response.StatusMessage,
			Trailers: response.Trailers,
		}
	}
	return response, nil
}
