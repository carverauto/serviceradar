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

package remoteaccess

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	defaultApplicationHTTPTimeout      = 30 * time.Second
	defaultApplicationMaxRequestBytes  = 10 * 1024 * 1024
	defaultApplicationMaxResponseBytes = 50 * 1024 * 1024
	tlsPolicyInsecureSkipVerify        = "insecure_skip_verify"
)

var (
	ErrApplicationMethodNotAllowed = errors.New("application method not allowed")
	ErrApplicationPathNotAllowed   = errors.New("application path not allowed")
	ErrApplicationRequestTooLarge  = errors.New("application request body exceeds quota")
	ErrApplicationResponseTooLarge = errors.New("application response body exceeds quota")
	ErrApplicationAdapterNil       = errors.New("application http adapter is nil")
	ErrApplicationSessionMismatch  = errors.New("application request session does not match open session")
)

type ApplicationHTTPAdapterOptions struct {
	RootCAs     *x509.CertPool
	DialContext func(context.Context, string, string) (net.Conn, error)
	Timeout     time.Duration
}

type ApplicationHTTPAdapter struct {
	open   ApplicationOpenPayload
	client *http.Client
}

type ApplicationHTTPResult struct {
	Metadata ApplicationResponseMetadataPayload
	Data     ApplicationDataPayload
	Progress ApplicationProgressPayload
	Outcome  ApplicationOutcomePayload
}

func NewApplicationHTTPAdapter(open ApplicationOpenPayload, opts ApplicationHTTPAdapterOptions) (*ApplicationHTTPAdapter, error) {
	if err := open.Validate(); err != nil {
		return nil, err
	}

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = defaultApplicationHTTPTimeout
	}

	transport := &http.Transport{
		DialContext: opts.DialContext,
		TLSClientConfig: &tls.Config{
			RootCAs:            opts.RootCAs,
			ServerName:         strings.TrimSpace(open.SNI),
			InsecureSkipVerify: tlsInsecureSkipVerify(open.TLSPolicy), //nolint:gosec // target policy controls this audited exception
			MinVersion:         tls.VersionTLS12,
		},
		Proxy: nil,
	}

	if transport.DialContext == nil {
		transport.DialContext = (&net.Dialer{Timeout: timeout}).DialContext
	}

	return &ApplicationHTTPAdapter{
		open: open,
		client: &http.Client{
			Transport: transport,
			Timeout:   timeout,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

func (a *ApplicationHTTPAdapter) Execute(
	ctx context.Context,
	request ApplicationRequestPayload,
	body []byte,
) (ApplicationHTTPResult, error) {
	if a == nil {
		return ApplicationHTTPResult{}, ErrApplicationAdapterNil
	}
	if err := request.Validate(); err != nil {
		return ApplicationHTTPResult{}, err
	}
	if request.SessionID != a.open.SessionID {
		return ApplicationHTTPResult{}, ErrApplicationSessionMismatch
	}
	if err := a.authorizeRequest(request, int64(len(body))); err != nil {
		return ApplicationHTTPResult{}, err
	}

	httpReq, err := a.buildRequest(ctx, request, body)
	if err != nil {
		return ApplicationHTTPResult{}, err
	}

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return ApplicationHTTPResult{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	responseBody, err := readApplicationBody(resp.Body, maxResponseBytes(a.open.QuotaPolicy))
	if err != nil {
		return ApplicationHTTPResult{}, err
	}

	return a.result(request, resp, body, responseBody), nil
}

func (a *ApplicationHTTPAdapter) Close() {
	if a == nil || a.client == nil {
		return
	}
	if transport, ok := a.client.Transport.(*http.Transport); ok {
		transport.CloseIdleConnections()
	}
}

func (a *ApplicationHTTPAdapter) MaxRequestBodyBytes() int64 {
	if a == nil {
		return 0
	}

	return maxRequestBytes(a.open.QuotaPolicy)
}

func (a *ApplicationHTTPAdapter) authorizeRequest(request ApplicationRequestPayload, bodyBytes int64) error {
	if !methodAllowed(request.Method, a.open.AllowedMethods) {
		return fmt.Errorf("%w %q", ErrApplicationMethodNotAllowed, request.Method)
	}
	if !applicationPathAllowed(request.Path, a.open.AllowedPathPrefixes) {
		return fmt.Errorf("%w %q", ErrApplicationPathNotAllowed, request.Path)
	}
	if max := maxRequestBytes(a.open.QuotaPolicy); max > 0 && bodyBytes > max {
		return ErrApplicationRequestTooLarge
	}

	return nil
}

func (a *ApplicationHTTPAdapter) buildRequest(
	ctx context.Context,
	request ApplicationRequestPayload,
	body []byte,
) (*http.Request, error) {
	upstreamURL := url.URL{
		Scheme: string(a.open.Scheme),
		Host:   net.JoinHostPort(a.open.UpstreamHost, strconv.Itoa(a.open.UpstreamPort)),
		Path:   request.Path,
	}
	upstreamURL.RawQuery = request.Query

	httpReq, err := http.NewRequestWithContext(ctx, strings.ToUpper(request.Method), upstreamURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header = sanitizedApplicationHeaders(request.Headers)
	if a.open.HostHeader != "" {
		httpReq.Host = a.open.HostHeader
	}

	return httpReq, nil
}

func (a *ApplicationHTTPAdapter) result(
	request ApplicationRequestPayload,
	resp *http.Response,
	requestBody []byte,
	body []byte,
) ApplicationHTTPResult {
	requestBytes := int64(len(requestBody))
	responseBytes := int64(len(body))

	return ApplicationHTTPResult{
		Metadata: ApplicationResponseMetadataPayload{
			RequestID:   request.RequestID,
			SessionID:   request.SessionID,
			StatusCode:  resp.StatusCode,
			Headers:     sanitizedApplicationHeaders(resp.Header),
			ContentType: resp.Header.Get("Content-Type"),
		},
		Data: ApplicationDataPayload{
			RequestID: request.RequestID,
			SessionID: request.SessionID,
			Direction: ApplicationDataDirectionResponse,
			Sequence:  1,
			Data:      body,
			EOF:       true,
		},
		Progress: ApplicationProgressPayload{
			RequestID:     request.RequestID,
			SessionID:     request.SessionID,
			Status:        ApplicationStatusCompleted,
			RequestBytes:  requestBytes,
			ResponseBytes: responseBytes,
		},
		Outcome: ApplicationOutcomePayload{
			SessionID:     request.SessionID,
			TargetID:      a.open.TargetID,
			Status:        ApplicationStatusCompleted,
			RequestCount:  1,
			RequestBytes:  requestBytes,
			ResponseBytes: responseBytes,
		},
	}
}

func methodAllowed(method string, allowed []string) bool {
	method = strings.ToUpper(strings.TrimSpace(method))
	if method == http.MethodConnect {
		return false
	}
	if len(allowed) == 0 {
		return true
	}
	for _, candidate := range allowed {
		if method == strings.ToUpper(strings.TrimSpace(candidate)) {
			return true
		}
	}

	return false
}

func applicationPathAllowed(path string, allowedPrefixes []string) bool {
	if len(allowedPrefixes) == 0 {
		return true
	}
	for _, prefix := range allowedPrefixes {
		if prefix == "/" || path == prefix || strings.HasPrefix(path, strings.TrimRight(prefix, "/")+"/") {
			return true
		}
	}

	return false
}

func sanitizedApplicationHeaders(headers map[string][]string) http.Header {
	result := make(http.Header)
	for key, values := range headers {
		if denyApplicationHeader(key) {
			continue
		}
		for _, value := range values {
			result.Add(key, value)
		}
	}

	return result
}

func denyApplicationHeader(key string) bool {
	switch strings.ToLower(strings.TrimSpace(key)) {
	case "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
		"te", "trailer", "transfer-encoding", "upgrade", "authorization", "cookie",
		"set-cookie", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto":
		return true
	default:
		return false
	}
}

func readApplicationBody(body io.Reader, maxBytes int64) ([]byte, error) {
	if maxBytes <= 0 {
		return io.ReadAll(body)
	}

	data, err := io.ReadAll(io.LimitReader(body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, ErrApplicationResponseTooLarge
	}

	return data, nil
}

func maxRequestBytes(policy map[string]any) int64 {
	if max := positivePolicyInt64(policy, "max_request_bytes"); max > 0 {
		return max
	}

	return defaultApplicationMaxRequestBytes
}

func maxResponseBytes(policy map[string]any) int64 {
	if max := positivePolicyInt64(policy, "max_response_bytes"); max > 0 {
		return max
	}

	return defaultApplicationMaxResponseBytes
}

func positivePolicyInt64(policy map[string]any, key string) int64 {
	switch value := policy[key].(type) {
	case int:
		return positiveInt64(int64(value))
	case int64:
		return positiveInt64(value)
	case float64:
		return positiveInt64(int64(value))
	case string:
		parsed, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return 0
		}
		return positiveInt64(parsed)
	default:
		return 0
	}
}

func positiveInt64(value int64) int64 {
	if value > 0 {
		return value
	}

	return 0
}

func tlsInsecureSkipVerify(policy map[string]any) bool {
	mode, _ := policy["mode"].(string)
	return mode == tlsPolicyInsecureSkipVerify || mode == sshHostKeyPolicySkipVerify
}
