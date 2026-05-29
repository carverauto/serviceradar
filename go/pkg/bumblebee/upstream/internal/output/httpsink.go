// HTTP sink for the output package. Buffers NDJSON records in memory
// and POSTs them in fixed-size batches to a generic HTTPS log-ingest
// endpoint.
//
// The sink is transport-agnostic. It does not encode any vendor-specific
// schema, headers, or signing scheme. Operators wire it to whatever
// receiver they run: a self-hosted HTTPS relay, a commercial log
// collector that accepts custom JSON, or a small Lambda/Cloud Run that
// forwards to object storage.

package output

import (
	"bytes"
	"compress/gzip"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// HTTPAuth describes how an HTTPSink authenticates each request.
type HTTPAuth struct {
	// Mode is "none", "bearer", or "hmac-sha256".
	Mode string
	// Token is the bearer token (for Mode == "bearer").
	Token string
	// HMACKey is the shared secret bytes (for Mode == "hmac-sha256").
	HMACKey []byte
	// HMACHeader is the header name used to carry the signature.
	// Defaults to "X-Inventory-Signature".
	HMACHeader string
	// TimestampHeader, if non-empty, receives the unix-seconds timestamp
	// that is also prefixed onto the signed payload as "<ts>.<body>".
	TimestampHeader string
}

// HTTPConfig configures an HTTPSink.
type HTTPConfig struct {
	URL       string
	Auth      HTTPAuth
	Timeout   time.Duration
	BatchSize int
	UserAgent string
	// AllowInsecure permits plain http:// to non-loopback hosts. Off by
	// default; loopback is always allowed for testing.
	AllowInsecure bool
	// Gzip enables gzip compression of the POST body. The Content-Type
	// remains application/x-ndjson and Content-Encoding: gzip is set.
	// When auth=hmac-sha256, the signature is computed over the
	// on-the-wire (compressed) bytes, so receivers verify the HMAC
	// against the raw POST body and only then decompress.
	Gzip bool
	// HTTPClient is used for the POST. Tests inject a stub.
	HTTPClient *http.Client
}

// HTTPSink implements io.WriteCloser. Each Write must be one complete
// NDJSON line (the json.Encoder used by Emitter writes one line per
// Encode call). Lines are buffered until BatchSize is reached, then
// flushed as a single application/x-ndjson POST. Close flushes any
// remaining lines.
type HTTPSink struct {
	cfg    HTTPConfig
	client *http.Client

	mu      sync.Mutex
	buf     bytes.Buffer
	inBatch int
	err     error
	closed  bool
	stats   SinkStats
}

const (
	defaultBatchSize   = 500
	defaultTimeout     = 30 * time.Second
	defaultHMACHeader  = "X-Inventory-Signature"
	contentTypeNDJSON  = "application/x-ndjson"
	maxResponseSnippet = 512
)

// NewHTTPSink validates cfg and constructs the sink.
func NewHTTPSink(cfg HTTPConfig) (*HTTPSink, error) {
	if err := validateHTTPConfig(&cfg); err != nil {
		return nil, err
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: cfg.Timeout}
	}
	return &HTTPSink{cfg: cfg, client: client}, nil
}

func validateHTTPConfig(cfg *HTTPConfig) error {
	if cfg.URL == "" {
		return errors.New("http sink: url is required")
	}
	u, err := url.Parse(cfg.URL)
	if err != nil {
		return fmt.Errorf("http sink: invalid url: %w", err)
	}
	if u.Scheme != "https" && u.Scheme != "http" {
		return fmt.Errorf("http sink: url scheme must be http or https, got %q", u.Scheme)
	}
	if u.Scheme == "http" && !cfg.AllowInsecure && !isLoopbackHost(u.Hostname()) {
		return errors.New("http sink: refusing plain http to non-loopback host; use https or set allow-insecure for testing")
	}
	switch cfg.Auth.Mode {
	case "", "none":
		cfg.Auth.Mode = "none"
	case "bearer":
		if cfg.Auth.Token == "" {
			return errors.New("http sink: bearer auth requires a token")
		}
	case "hmac-sha256":
		if len(cfg.Auth.HMACKey) == 0 {
			return errors.New("http sink: hmac-sha256 auth requires a key")
		}
		if cfg.Auth.HMACHeader == "" {
			cfg.Auth.HMACHeader = defaultHMACHeader
		}
	default:
		return fmt.Errorf("http sink: unknown auth mode %q", cfg.Auth.Mode)
	}
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = defaultBatchSize
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = defaultTimeout
	}
	return nil
}

func isLoopbackHost(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// Write appends one NDJSON line to the buffer and flushes when full.
// It returns the bytes accepted, never partial, so the json.Encoder is
// happy.
func (h *HTTPSink) Write(p []byte) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return 0, errors.New("http sink: write after close")
	}
	if h.err != nil {
		return 0, h.err
	}
	n, _ := h.buf.Write(p)
	// json.Encoder.Encode writes one record terminated by '\n'.
	if bytes.Count(p, []byte{'\n'}) > 0 {
		h.inBatch += bytes.Count(p, []byte{'\n'})
	}
	if h.inBatch >= h.cfg.BatchSize {
		if err := h.flushLocked(); err != nil {
			h.err = err
			return n, err
		}
	}
	return n, nil
}

// Close flushes any buffered records.
func (h *HTTPSink) Close() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return nil
	}
	h.closed = true
	if h.err != nil {
		return h.err
	}
	if h.buf.Len() == 0 {
		return nil
	}
	return h.flushLocked()
}

func (h *HTTPSink) flushLocked() error {
	body := make([]byte, h.buf.Len())
	copy(body, h.buf.Bytes())
	h.buf.Reset()
	h.inBatch = 0

	wireBody := body
	if h.cfg.Gzip {
		var gz bytes.Buffer
		zw := gzip.NewWriter(&gz)
		if _, werr := zw.Write(body); werr != nil {
			return fmt.Errorf("http sink: gzip: %w", werr)
		}
		if cerr := zw.Close(); cerr != nil {
			return fmt.Errorf("http sink: gzip close: %w", cerr)
		}
		wireBody = gz.Bytes()
	}

	req, err := http.NewRequest(http.MethodPost, h.cfg.URL, bytes.NewReader(wireBody))
	if err != nil {
		return fmt.Errorf("http sink: build request: %w", err)
	}
	req.Header.Set("Content-Type", contentTypeNDJSON)
	if h.cfg.Gzip {
		req.Header.Set("Content-Encoding", "gzip")
	}
	if h.cfg.UserAgent != "" {
		req.Header.Set("User-Agent", h.cfg.UserAgent)
	}
	if err := applyAuth(req, h.cfg.Auth, wireBody); err != nil {
		return err
	}

	h.stats.HTTPBatchesAttempted++
	resp, err := h.client.Do(req)
	if err != nil {
		h.stats.HTTPBatchesFailed++
		h.stats.HTTPLastStatus = 0
		return fmt.Errorf("http sink: post: %w", err)
	}
	defer resp.Body.Close()
	h.stats.HTTPLastStatus = resp.StatusCode
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		h.stats.HTTPBatchesFailed++
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, maxResponseSnippet))
		return fmt.Errorf("http sink: server returned %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	// Drain any remaining body so the connection can be reused.
	_, _ = io.Copy(io.Discard, resp.Body)
	h.stats.HTTPBatchesSucceeded++
	return nil
}

// Stats returns best-effort delivery counters for scan_summary
// emission. Counters reflect batches the sink has already attempted;
// the final flush that delivers the scan_summary batch itself runs
// during Close and is not reflected in the stats stamped onto that
// summary record.
func (h *HTTPSink) Stats() SinkStats {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.stats
}

func applyAuth(req *http.Request, a HTTPAuth, body []byte) error {
	switch a.Mode {
	case "none":
		return nil
	case "bearer":
		req.Header.Set("Authorization", "Bearer "+a.Token)
		return nil
	case "hmac-sha256":
		var signedPayload []byte
		if a.TimestampHeader != "" {
			ts := strconv.FormatInt(time.Now().Unix(), 10)
			req.Header.Set(a.TimestampHeader, ts)
			signedPayload = append([]byte(ts+"."), body...)
		} else {
			signedPayload = body
		}
		mac := hmac.New(sha256.New, a.HMACKey)
		mac.Write(signedPayload)
		sig := hex.EncodeToString(mac.Sum(nil))
		header := a.HMACHeader
		if header == "" {
			header = defaultHMACHeader
		}
		req.Header.Set(header, "sha256="+sig)
		return nil
	default:
		return fmt.Errorf("http sink: unknown auth mode %q", a.Mode)
	}
}
