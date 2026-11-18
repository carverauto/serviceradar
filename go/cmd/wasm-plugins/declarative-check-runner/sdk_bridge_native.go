//go:build !tinygo

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"strings"
	"time"
)

func executeEntrypoint(fn func() (*pluginResult, error)) {
	_, _ = fn()
}

func primeTinyGoReflection() {}

func fillRandomBytes(buf []byte) error {
	_, err := rand.Read(buf)
	return err
}

func defaultRunnerDeps() RunnerDeps {
	return RunnerDeps{
		Now: func() time.Time { return time.Now().UTC() },
		LoadConfigRaw: func() ([]byte, error) {
			return []byte(`{}`), nil
		},
		HTTPDo:  doNativeHTTPRequest,
		TCPDial: dialNativeTCP,
		EmitMetrics: func(_ string, _ []metricSample, _ time.Time) error {
			return nil
		},
	}
}

func dialNativeTCP(host string, port uint16, timeout time.Duration) (streamConn, error) {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return net.DialTimeout("tcp", net.JoinHostPort(host, itoa(int(port))), timeout)
}

func doNativeHTTPRequest(req hostHTTPReq) (*hostHTTPResp, error) {
	timeout := 10 * time.Second
	if req.TimeoutMS > 0 {
		timeout = time.Duration(req.TimeoutMS) * time.Millisecond
	}
	method := strings.ToUpper(strings.TrimSpace(req.Method))
	if method == "" {
		method = http.MethodGet
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	var (
		dnsStart, dnsDone   time.Time
		tcpStart, tcpDone   time.Time
		tlsStart, tlsDone   time.Time
		firstByte           time.Time
		start               = time.Now()
		gotFirstResponseBit bool
	)

	trace := &httptrace.ClientTrace{
		DNSStart:          func(_ httptrace.DNSStartInfo) { dnsStart = time.Now() },
		DNSDone:           func(_ httptrace.DNSDoneInfo) { dnsDone = time.Now() },
		ConnectStart:      func(_, _ string) { tcpStart = time.Now() },
		ConnectDone:       func(_, _ string, _ error) { tcpDone = time.Now() },
		TLSHandshakeStart: func() { tlsStart = time.Now() },
		TLSHandshakeDone:  func(_ tls.ConnectionState, _ error) { tlsDone = time.Now() },
		GotFirstResponseByte: func() {
			firstByte = time.Now()
			gotFirstResponseBit = true
		},
	}

	httpReq, err := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace), method, req.URL, bytes.NewReader(req.Body))
	if err != nil {
		return nil, err
	}
	for k, v := range req.Headers {
		if strings.TrimSpace(k) != "" {
			httpReq.Header.Set(k, v)
		}
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: req.InsecureSkipVerify, //nolint:gosec // explicit opt-in for synthetic probe testing
		},
	}
	client := &http.Client{
		Timeout:   timeout,
		Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024))
	if err != nil {
		return nil, err
	}
	total := time.Since(start)

	headers := make(map[string]string, len(resp.Header))
	for k, vals := range resp.Header {
		if len(vals) > 0 {
			headers[k] = strings.Join(vals, ",")
		}
	}

	timing := &hostHTTPTrace{
		TotalMS: durationMS(total),
	}
	if !dnsStart.IsZero() && !dnsDone.IsZero() {
		timing.DNSMS = durationMS(dnsDone.Sub(dnsStart))
	}
	if !tcpStart.IsZero() && !tcpDone.IsZero() {
		timing.TCPMS = durationMS(tcpDone.Sub(tcpStart))
	}
	if !tlsStart.IsZero() && !tlsDone.IsZero() {
		timing.TLSMS = durationMS(tlsDone.Sub(tlsStart))
	}
	if gotFirstResponseBit {
		timing.TTFBMS = durationMS(firstByte.Sub(start))
		timing.TransferMS = durationMS(total - firstByte.Sub(start))
	}

	return &hostHTTPResp{
		Status:   resp.StatusCode,
		Headers:  headers,
		Body:     body,
		Duration: total,
		Trace:    timing,
	}, nil
}

func marshalNativeTelemetryJSON(v any) ([]byte, error) {
	return json.Marshal(v)
}
