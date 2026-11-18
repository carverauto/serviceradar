package sdk

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// HTTP response modes accepted by the host's http_request import.
const (
	// ResponseModeStatusBody returns only the status line and body. Response
	// headers are dropped. It is the SDK default.
	ResponseModeStatusBody = "status_body"
	// ResponseModeEnvelope returns a JSON envelope that also carries the
	// response headers. Multiple values for one header arrive comma-joined.
	ResponseModeEnvelope = "envelope"
)

// HTTPRequest defines a proxied HTTP request.
type HTTPRequest struct {
	Method     string
	URL        string
	Headers    map[string]string
	Body       []byte
	BodyBase64 bool
	// ResponseMode selects the host response encoding. Empty uses
	// ResponseModeStatusBody, which drops response headers; set
	// ResponseModeEnvelope to receive them in HTTPResponse.Headers.
	ResponseMode       string
	TimeoutMS          int
	InsecureSkipVerify bool
	// FollowRedirects controls whether the host follows 3xx redirects.
	// When nil, the host defaults to following allowed redirects.
	FollowRedirects *bool
}

// Bool returns a pointer to v for optional boolean request fields.
func Bool(v bool) *bool {
	return &v
}

// HTTPHopTrace records phase timings and metadata for one HTTP request hop.
type HTTPHopTrace struct {
	URL                    string `json:"url"`
	Status                 int    `json:"status"`
	DNSDurationNS          int64  `json:"dns_duration_ns"`
	ConnectDurationNS      int64  `json:"connect_duration_ns"`
	TLSHandshakeDurationNS int64  `json:"tls_handshake_duration_ns"`
	TTFBDurationNS         int64  `json:"ttfb_duration_ns"`
	RemoteAddr             string `json:"remote_addr,omitempty"`
}

// HTTPTrace records host-side net/http/httptrace phase waterfall timings.
type HTTPTrace struct {
	DNSDurationNS          int64          `json:"dns_duration_ns"`
	ConnectDurationNS      int64          `json:"connect_duration_ns"`
	TLSHandshakeDurationNS int64          `json:"tls_handshake_duration_ns"`
	TTFBDurationNS         int64          `json:"ttfb_duration_ns"`
	TransferDurationNS     int64          `json:"transfer_duration_ns"`
	TotalDurationNS        int64          `json:"total_duration_ns"`
	ConnectionReused       bool           `json:"connection_reused"`
	RedirectCount          int            `json:"redirect_count"`
	FinalURL               string         `json:"final_url"`
	Protocol               string         `json:"protocol,omitempty"`
	RemoteAddr             string         `json:"remote_addr,omitempty"`
	Hops                   []HTTPHopTrace `json:"hops,omitempty"`
}

// HTTPTLSInfo records negotiated TLS connection posture and leaf certificate metadata.
type HTTPTLSInfo struct {
	Version           string `json:"version,omitempty"`
	CipherSuite       string `json:"cipher_suite,omitempty"`
	ALPN              string `json:"alpn,omitempty"`
	LeafSubjectCN     string `json:"leaf_subject_cn,omitempty"`
	LeafIssuerCN      string `json:"leaf_issuer_cn,omitempty"`
	LeafNotAfterUnix  int64  `json:"leaf_not_after_unix"`
	LeafDaysRemaining int    `json:"leaf_days_remaining"`
}

// HTTPResponse contains the proxied response data. Headers, SetCookies, Trace,
// and TLS are populated only in ResponseModeEnvelope.
type HTTPResponse struct {
	Status     int
	Headers    map[string]string
	SetCookies []string
	Body       []byte
	Duration   time.Duration
	Trace      *HTTPTrace
	TLS        *HTTPTLSInfo
}

// Header returns the named response header, matched case-insensitively, or ""
// when it is absent.
func (r *HTTPResponse) Header(name string) string {
	if r == nil {
		return ""
	}
	if value, ok := r.Headers[name]; ok {
		return value
	}
	for key, value := range r.Headers {
		if strings.EqualFold(key, name) {
			return value
		}
	}
	return ""
}

// HeaderValues returns all values for the named response header, matched
// case-insensitively. For Set-Cookie, unjoined SetCookies are returned when
// populated by the host envelope.
func (r *HTTPResponse) HeaderValues(name string) []string {
	if r == nil {
		return nil
	}
	if strings.EqualFold(name, "Set-Cookie") && len(r.SetCookies) > 0 {
		out := make([]string, len(r.SetCookies))
		copy(out, r.SetCookies)
		return out
	}
	if value := r.Header(name); value != "" {
		return []string{value}
	}
	return nil
}

// RetryAfter parses the Retry-After header as delta-seconds or an HTTP-date.
// A date in the past yields zero. It reports false when the header is absent
// or malformed.
func (r *HTTPResponse) RetryAfter() (time.Duration, bool) {
	return r.retryAfterAt(time.Now())
}

func (r *HTTPResponse) retryAfterAt(now time.Time) (time.Duration, bool) {
	value := strings.TrimSpace(r.Header("Retry-After"))
	if value == "" {
		return 0, false
	}
	if value[0] >= '0' && value[0] <= '9' {
		seconds, err := strconv.ParseInt(value, 10, 64)
		if err != nil || seconds > int64(1<<63-1)/int64(time.Second) {
			return 0, false
		}
		return time.Duration(seconds) * time.Second, true
	}
	at, err := http.ParseTime(value)
	if err != nil {
		return 0, false
	}
	if wait := at.Sub(now); wait > 0 {
		return wait, true
	}
	return 0, true
}

type httpRequestPayload struct {
	Method             string            `json:"method"`
	URL                string            `json:"url"`
	Headers            map[string]string `json:"headers,omitempty"`
	Body               string            `json:"body,omitempty"`
	BodyBase64         string            `json:"body_base64,omitempty"`
	ResponseMode       string            `json:"response_mode,omitempty"`
	TimeoutMS          int               `json:"timeout_ms,omitempty"`
	InsecureSkipVerify bool              `json:"insecure_skip_verify,omitempty"`
	FollowRedirects    *bool             `json:"follow_redirects,omitempty"`
}

type httpResponsePayload struct {
	Status       int               `json:"status"`
	Headers      map[string]string `json:"headers,omitempty"`
	SetCookies   []string          `json:"set_cookies,omitempty"`
	BodyBase64   string            `json:"body_base64"`
	BodyEncoding string            `json:"body_encoding,omitempty"`
	Trace        *HTTPTrace        `json:"trace,omitempty"`
	TLS          *HTTPTLSInfo      `json:"tls,omitempty"`
}

// HTTP provides helper methods for host-proxied HTTP requests.
//
//nolint:gochecknoglobals
var HTTP = &HTTPClient{MaxResponseBytes: MaxHTTPResponseBytes}

// HTTPClient wraps host HTTP request calls.
type HTTPClient struct {
	MaxResponseBytes uint32
}

// Do performs an HTTP request via the host proxy.
func (c *HTTPClient) Do(req HTTPRequest) (*HTTPResponse, error) {
	return c.DoContext(context.Background(), req)
}

// DoContext performs an HTTP request via the host proxy with a context.
func (c *HTTPClient) DoContext(ctx context.Context, req HTTPRequest) (*HTTPResponse, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	payload := httpRequestPayload{
		Method:             strings.ToUpper(strings.TrimSpace(req.Method)),
		URL:                req.URL,
		Headers:            req.Headers,
		ResponseMode:       strings.TrimSpace(req.ResponseMode),
		TimeoutMS:          req.TimeoutMS,
		InsecureSkipVerify: req.InsecureSkipVerify,
		FollowRedirects:    req.FollowRedirects,
	}

	if payload.Method == "" {
		payload.Method = http.MethodGet
	}
	if payload.ResponseMode == "" {
		payload.ResponseMode = ResponseModeStatusBody
	}

	if len(req.Body) > 0 {
		if req.BodyBase64 {
			payload.BodyBase64 = base64.StdEncoding.EncodeToString(req.Body)
		} else {
			payload.Body = string(req.Body)
		}
	}

	encoded := marshalHTTPRequestPayload(payload)

	respBufSize := c.MaxResponseBytes
	if respBufSize == 0 {
		respBufSize = MaxHTTPResponseBytes
	}

	respBuf := make([]byte, respBufSize)
	start := time.Now()
	res := callHostHTTPRequest(encoded, respBuf)

	if err := hostErr(res, "http_request"); err != nil {
		return nil, err
	}
	if res == 0 {
		return &HTTPResponse{Duration: time.Since(start)}, nil
	}
	if uint32(res) > uint32(len(respBuf)) {
		return nil, HostError{Code: hostErrTooLarge, Op: "http_request"}
	}

	response, ok, err := decodeStatusBodyHTTPResponse(respBuf[:res], time.Since(start))
	if err != nil {
		return nil, err
	}
	if ok {
		return response, nil
	}

	return decodeEnvelopeHTTPResponse(respBuf[:res], time.Since(start))
}

func decodeStatusBodyHTTPResponse(payload []byte, duration time.Duration) (*HTTPResponse, bool, error) {
	lineEnd := -1

	for i, ch := range payload {
		if ch == '\n' {
			lineEnd = i
			break
		}
		if ch < '0' || ch > '9' {
			return nil, false, nil
		}
	}
	if lineEnd <= 0 {
		return nil, false, nil
	}

	status, err := parseHTTPStatus(payload[:lineEnd])
	if err != nil {
		return nil, true, err
	}

	return &HTTPResponse{
		Status:   status,
		Body:     payload[lineEnd+1:],
		Duration: duration,
	}, true, nil
}

func decodeEnvelopeHTTPResponse(payload []byte, duration time.Duration) (*HTTPResponse, error) {
	var responsePayload httpResponsePayload

	if err := json.Unmarshal(payload, &responsePayload); err != nil {
		return nil, err
	}

	body, err := base64.StdEncoding.DecodeString(responsePayload.BodyBase64)
	if err != nil {
		return nil, err
	}

	return &HTTPResponse{
		Status:     responsePayload.Status,
		Headers:    responsePayload.Headers,
		SetCookies: responsePayload.SetCookies,
		Body:       body,
		Duration:   duration,
		Trace:      responsePayload.Trace,
		TLS:        responsePayload.TLS,
	}, nil
}

func parseHTTPStatus(value []byte) (int, error) {
	status := 0
	for _, ch := range value {
		if ch < '0' || ch > '9' {
			return 0, fmt.Errorf("invalid http status byte %q", ch)
		}
		status = status*10 + int(ch-'0')
	}
	return status, nil
}

func marshalHTTPRequestPayload(payload httpRequestPayload) []byte {
	var b strings.Builder

	b.Grow(len(payload.URL) + len(payload.Body) + len(payload.BodyBase64) + 160)
	b.WriteString(`{"method":`)
	writeJSONString(&b, payload.Method)
	b.WriteString(`,"url":`)
	writeJSONString(&b, payload.URL)

	if len(payload.Headers) > 0 {
		b.WriteString(`,"headers":{`)
		i := 0
		for key, value := range payload.Headers {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSONString(&b, key)
			b.WriteByte(':')
			writeJSONString(&b, value)
			i++
		}
		b.WriteByte('}')
	}

	if payload.Body != "" {
		b.WriteString(`,"body":`)
		writeJSONString(&b, payload.Body)
	}
	if payload.BodyBase64 != "" {
		b.WriteString(`,"body_base64":`)
		writeJSONString(&b, payload.BodyBase64)
	}
	if payload.ResponseMode != "" {
		b.WriteString(`,"response_mode":`)
		writeJSONString(&b, payload.ResponseMode)
	}
	if payload.TimeoutMS > 0 {
		b.WriteString(`,"timeout_ms":`)
		b.WriteString(fmt.Sprintf("%d", payload.TimeoutMS))
	}
	if payload.InsecureSkipVerify {
		b.WriteString(`,"insecure_skip_verify":true`)
	}
	if payload.FollowRedirects != nil {
		if *payload.FollowRedirects {
			b.WriteString(`,"follow_redirects":true`)
		} else {
			b.WriteString(`,"follow_redirects":false`)
		}
	}
	b.WriteByte('}')

	return []byte(b.String())
}

func writeJSONString(b *strings.Builder, value string) {
	b.WriteByte('"')
	for i := 0; i < len(value); i++ {
		ch := value[i]
		switch ch {
		case '\\', '"':
			b.WriteByte('\\')
			b.WriteByte(ch)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if ch < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[ch>>4])
				b.WriteByte(hex[ch&0x0f])
			} else {
				b.WriteByte(ch)
			}
		}
	}
	b.WriteByte('"')
}

// Get performs a GET request.
func (c *HTTPClient) Get(url string) (*HTTPResponse, error) {
	return c.DoContext(context.Background(), HTTPRequest{Method: http.MethodGet, URL: url})
}

// GetContext performs a GET request with a context.
func (c *HTTPClient) GetContext(ctx context.Context, url string) (*HTTPResponse, error) {
	return c.DoContext(ctx, HTTPRequest{Method: http.MethodGet, URL: url})
}

// Post performs a POST request with the provided body.
func (c *HTTPClient) Post(url string, body []byte, contentType string) (*HTTPResponse, error) {
	headers := map[string]string{}
	if contentType != "" {
		headers["content-type"] = contentType
	}

	return c.DoContext(context.Background(), HTTPRequest{Method: http.MethodPost, URL: url, Headers: headers, Body: body})
}

// PostContext performs a POST request with a context and provided body.
func (c *HTTPClient) PostContext(ctx context.Context, url string, body []byte, contentType string) (*HTTPResponse, error) {
	headers := map[string]string{}
	if contentType != "" {
		headers["content-type"] = contentType
	}

	return c.DoContext(ctx, HTTPRequest{Method: http.MethodPost, URL: url, Headers: headers, Body: body})
}
