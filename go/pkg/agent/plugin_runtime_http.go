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
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tetratelabs/wazero/api"
)

type httpRequestPayload struct {
	Method             string            `json:"method"`
	URL                string            `json:"url"`
	Headers            map[string]string `json:"headers"`
	Body               string            `json:"body"`
	BodyBase64         string            `json:"body_base64"`
	ResponseMode       string            `json:"response_mode"`
	TimeoutMS          int               `json:"timeout_ms"`
	InsecureSkipVerify bool              `json:"insecure_skip_verify"`
}

type httpResponsePayload struct {
	Status       int               `json:"status"`
	Headers      map[string]string `json:"headers,omitempty"`
	BodyBase64   string            `json:"body_base64"`
	BodyEncoding string            `json:"body_encoding,omitempty"`
}

// The insecure transport cache preserves connection reuse for the explicit
// plugin-level insecure TLS opt-in while keeping base client transports immutable.
//
//nolint:gochecknoglobals
var (
	pluginHTTPInsecureTransportMu    sync.Mutex
	pluginHTTPInsecureTransportCache = map[*http.Transport]*http.Transport{}
)

func (e *pluginExecution) hostHTTPRequest(ctx context.Context, mod api.Module, reqPtr, reqLen, respPtr, respLen uint32) int32 {
	if !e.hasCapability("http_request") {
		return pluginErrDenied
	}

	reqBytes, ok := readMemory(mod, reqPtr, reqLen)
	if !ok {
		return pluginErrInvalid
	}
	if len(reqBytes) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	var payload httpRequestPayload
	if err := json.Unmarshal(reqBytes, &payload); err != nil {
		return pluginErrInvalid
	}

	reqURL, err := url.Parse(strings.TrimSpace(payload.URL))
	if err != nil || reqURL.Host == "" {
		return pluginErrInvalid
	}

	method := strings.ToUpper(strings.TrimSpace(payload.Method))
	if method == "" {
		method = http.MethodGet
	}

	pluginBody, err := decodeBody(payload)
	if err != nil {
		return pluginErrInvalid
	}
	defer clear(pluginBody)

	proxmoxBinding, err := e.proxmoxHostAuthorityForHTTPRequest(
		method,
		reqURL,
		pluginBody,
		payload.InsecureSkipVerify,
	)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}
	if !pluginHTTPRequestDestinationAllowed(&e.assignment.Permissions, reqURL) &&
		!pluginHostAuthorityDestinationAllowed(&e.assignment.Permissions, reqURL, proxmoxBinding) {
		return pluginErrDenied
	}

	grant, err := e.credentialBrokerGrantForHTTP(method, reqURL)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}

	rewrittenBody, err := e.rewriteAWXCallbackCredentialBody(method, reqURL, pluginBody)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}
	defer clear(rewrittenBody)
	authorizedBody, authorizedContentType, err := e.authorizeCredentialBrokerHTTPRequestBody(
		grant,
		method,
		reqURL,
		rewrittenBody,
	)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}
	defer clear(authorizedBody)
	if err := e.reserveCredentialBrokerMutation(grant, method); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}

	timeout := pluginDefaultHTTPTimeout
	if payload.TimeoutMS > 0 {
		timeout = time.Duration(payload.TimeoutMS) * time.Millisecond
	}

	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(reqCtx, method, reqURL.String(), bytes.NewReader(authorizedBody))
	if err != nil {
		return pluginErrInvalid
	}

	for key, value := range payload.Headers {
		if strings.TrimSpace(key) == "" {
			continue
		}
		httpReq.Header.Set(key, value)
	}
	enforceCredentialBrokerContentType(httpReq, authorizedContentType)
	hostCredentialBound, err := e.applyAWXInventoryHostCredential(
		httpReq,
		payload.InsecureSkipVerify,
	)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}
	if err := e.applyProxmoxHostAuthorityCredential(ctx, httpReq, proxmoxBinding); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}
	hostCredentialBound = hostCredentialBound || proxmoxBinding != nil

	if err := e.applyCredentialBrokerInjection(ctx, httpReq, grant, payload.InsecureSkipVerify); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method)
		return pluginErrDenied
	}

	httpClient := pluginHTTPClient(e.manager.httpClient, payload.InsecureSkipVerify, timeout)
	configurePluginHTTPRedirects(httpClient, grant, reqURL, &e.assignment.Permissions)
	if hostCredentialBound {
		// Host-retained credentials are authorized for this one canonical
		// request. Redirect handling does not re-enter the host credential gate,
		// so never replay the bearer, including to a same-origin location.
		httpClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}
	if proxmoxBinding != nil {
		if err := e.ensureActiveProxmoxAssignment(reqCtx); err != nil {
			return pluginErrDenied
		}
	}
	resp, err := httpClient.Do(httpReq)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			e.logPluginHostHTTPFailure(err, reqURL, method, "timeout")
			return pluginErrTimeout
		}
		e.logPluginHostHTTPFailure(err, reqURL, method, "request_failed")
		return pluginErrInternal
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	limited := io.LimitReader(resp.Body, pluginMaxHTTPBodyBytes+1)
	bodyBytes, err := io.ReadAll(limited)
	if err != nil {
		e.logPluginHostHTTPFailure(err, reqURL, method, "read_failed")
		return pluginErrInternal
	}
	if int64(len(bodyBytes)) > pluginMaxHTTPBodyBytes {
		return pluginErrTooLarge
	}
	if proxmoxBinding != nil && e.assignment.PluginID == proxmoxConsolePluginID {
		protectedBody, protectErr := e.protectProxmoxConsoleProxyResponse(
			proxmoxBinding,
			reqURL,
			resp.StatusCode,
			bodyBytes,
		)
		if protectErr != nil {
			clear(bodyBytes)
			return pluginErrDenied
		}
		if resp.StatusCode >= http.StatusOK && resp.StatusCode < http.StatusMultipleChoices {
			clear(bodyBytes)
			bodyBytes = protectedBody
		}
	}
	defer clear(bodyBytes)

	if strings.EqualFold(strings.TrimSpace(payload.ResponseMode), "status_body") {
		responseBytes := []byte(strconv.Itoa(resp.StatusCode) + "\n")
		responseBytes = append(responseBytes, bodyBytes...)
		if len(responseBytes) > int(respLen) {
			return pluginErrTooLarge
		}
		if !writeMemory(mod, respPtr, responseBytes) {
			return pluginErrInvalid
		}
		return int32(len(responseBytes))
	}

	responsePayload := httpResponsePayload{
		Status:       resp.StatusCode,
		Headers:      flattenHeaders(resp.Header),
		BodyBase64:   base64.StdEncoding.EncodeToString(bodyBytes),
		BodyEncoding: "base64",
	}

	responseBytes, err := json.Marshal(responsePayload)
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

func pluginHTTPRequestDestinationAllowed(permissions *pluginPermissions, reqURL *url.URL) bool {
	if permissions == nil || reqURL == nil || reqURL.Host == "" {
		return false
	}

	port, ok := pluginHTTPRequestPort(reqURL)
	return ok && permissions.allowsHTTPPort(port) && permissions.allowsHTTPHost(reqURL.Hostname())
}

func pluginHTTPRequestPort(reqURL *url.URL) (int, bool) {
	if reqURL == nil {
		return 0, false
	}

	var defaultPort int
	switch strings.ToLower(strings.TrimSpace(reqURL.Scheme)) {
	case "http":
		defaultPort = 80
	case "https":
		defaultPort = 443
	default:
		return 0, false
	}

	rawPort := reqURL.Port()
	if rawPort == "" {
		return defaultPort, true
	}

	port, err := strconv.Atoi(rawPort)
	if err != nil || port < 1 || port > 65535 {
		return 0, false
	}

	return port, true
}

func configurePluginHTTPRedirects(
	client *http.Client,
	grant *credentialBrokerGrant,
	requestURL *url.URL,
	permissions *pluginPermissions,
) {
	strictAWXGrant := grant != nil &&
		strings.EqualFold(strings.TrimSpace(grant.GrantType), "awx_oauth2_token")
	if client == nil {
		return
	}

	// A broker grant is authorized for one canonical request. Go's redirect
	// handling does not re-enter the plugin host boundary, so following even a
	// same-host redirect would bypass the grant's method/path/port checks.
	if strictAWXGrant || awxCredentialEndpoint(requestURL) || awxReviewedCredentialTypeEndpoint(requestURL) {
		client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}
		return
	}

	previousCheckRedirect := client.CheckRedirect
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if req == nil || !pluginHTTPRequestDestinationAllowed(permissions, req.URL) {
			return http.ErrUseLastResponse
		}
		if previousCheckRedirect != nil {
			return previousCheckRedirect(req, via)
		}
		if len(via) >= 10 {
			return errors.New("stopped after 10 redirects")
		}
		return nil
	}
}

func (e *pluginExecution) credentialBrokerGrantForHTTP(method string, reqURL *url.URL) (*credentialBrokerGrant, error) {
	if e == nil || e.mode != pluginExecutionModeAction || len(e.credentialGrants) == 0 {
		return nil, nil
	}

	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}

	return pluginActionGrantForHTTPRequest(e.credentialGrants, method, reqURL, now)
}

func (e *pluginExecution) applyCredentialBrokerInjection(
	ctx context.Context,
	req *http.Request,
	grant *credentialBrokerGrant,
	insecureSkipVerify bool,
) error {
	if grant == nil || len(grant.Inject) == 0 {
		return nil
	}
	if insecureSkipVerify && !credentialBrokerGrantAllowsInsecureTLS(*grant) {
		return errCredentialBrokerInsecureTLSDenied
	}
	if e == nil || e.manager == nil || e.manager.credentialBrokerResolver() == nil {
		return errCredentialBrokerResolverUnavailable
	}

	material, err := e.manager.resolveCredentialBrokerMaterial(ctx, *grant)
	if err != nil {
		return err
	}

	return applyCredentialBrokerHTTPInjection(req, *grant, material)
}

func credentialBrokerGrantAllowsInsecureTLS(grant credentialBrokerGrant) bool {
	return strings.EqualFold(strings.TrimSpace(grant.Inject["allow_insecure_tls"]), "true")
}

func (m *PluginManager) resolveCredentialBrokerMaterial(
	ctx context.Context,
	grant credentialBrokerGrant,
) (CredentialBrokerMaterial, error) {
	resolver := m.credentialBrokerResolver()
	if resolver == nil {
		return CredentialBrokerMaterial{}, errCredentialBrokerResolverUnavailable
	}

	key, ttl := m.credentialBrokerCacheDecision(grant)
	if key == "" || ttl <= 0 {
		return resolver.ResolveCredentialGrant(ctx, grant)
	}

	now := m.credentialNowTime()
	if material, ok := m.getCachedCredentialBrokerMaterial(key, now); ok {
		return material, nil
	}

	material, err := resolver.ResolveCredentialGrant(ctx, grant)
	if err != nil {
		return CredentialBrokerMaterial{}, err
	}

	expiresAt := now.Add(ttl)
	if !material.LeaseExpiresAt.IsZero() {
		if !now.Before(material.LeaseExpiresAt) {
			return CredentialBrokerMaterial{}, errCredentialBrokerGrantExpired
		}
		if material.LeaseExpiresAt.Before(expiresAt) {
			expiresAt = material.LeaseExpiresAt
		}
	}

	m.putCachedCredentialBrokerMaterial(key, material, expiresAt)
	return material, nil
}

func (m *PluginManager) credentialBrokerCacheDecision(grant credentialBrokerGrant) (string, time.Duration) {
	mode := strings.ToLower(strings.TrimSpace(grant.Cache.Mode))
	if mode == "" || mode == "no_cache" || mode == "none" || mode == "disabled" {
		return "", 0
	}
	if mode != "memory" && mode != "memory_only" && mode != "memory_ttl" {
		return "", 0
	}

	ttlSeconds := grant.Cache.TTLSeconds
	if ttlSeconds <= 0 || ttlSeconds > 300 {
		ttlSeconds = 300
	}
	if grant.TTLSeconds > 0 && grant.TTLSeconds < ttlSeconds {
		ttlSeconds = grant.TTLSeconds
	}

	now := m.credentialNowTime()
	if expiresAt, ok := parseCredentialBrokerExpiresAt(grant.ExpiresAt); ok {
		remaining := expiresAt.Sub(now)
		if remaining <= 0 {
			return "", 0
		}
		if remaining < time.Duration(ttlSeconds)*time.Second {
			ttlSeconds = int(remaining / time.Second)
			if ttlSeconds <= 0 {
				return "", 0
			}
		}
	}

	key := strings.TrimSpace(grant.GrantID)
	if key == "" {
		key = strings.TrimSpace(grant.CredentialSecretRef)
	}
	if key == "" {
		return "", 0
	}

	return key, time.Duration(ttlSeconds) * time.Second
}

func (m *PluginManager) credentialBrokerResolver() CredentialBrokerResolver {
	if m == nil {
		return nil
	}

	m.credentialMu.Lock()
	defer m.credentialMu.Unlock()

	return m.credentialBroker
}

func (m *PluginManager) getCachedCredentialBrokerMaterial(
	key string,
	now time.Time,
) (CredentialBrokerMaterial, bool) {
	m.credentialMu.Lock()
	defer m.credentialMu.Unlock()

	entry, ok := m.credentialCache[key]
	if !ok || !now.Before(entry.expiresAt) {
		delete(m.credentialCache, key)
		return CredentialBrokerMaterial{}, false
	}

	return cloneCredentialBrokerMaterial(entry.material), true
}

func (m *PluginManager) putCachedCredentialBrokerMaterial(
	key string,
	material CredentialBrokerMaterial,
	expiresAt time.Time,
) {
	m.credentialMu.Lock()
	defer m.credentialMu.Unlock()

	m.credentialCache[key] = credentialBrokerCacheEntry{
		material:  cloneCredentialBrokerMaterial(material),
		expiresAt: expiresAt,
	}
}

func (m *PluginManager) credentialNowTime() time.Time {
	if m != nil && m.credentialNow != nil {
		return m.credentialNow()
	}
	return time.Now()
}

func cloneCredentialBrokerMaterial(material CredentialBrokerMaterial) CredentialBrokerMaterial {
	clone := CredentialBrokerMaterial{Value: material.Value, LeaseExpiresAt: material.LeaseExpiresAt}
	if material.Fields != nil {
		clone.Fields = make(map[string]string, len(material.Fields))
		for key, value := range material.Fields {
			clone.Fields[key] = value
		}
	}
	return clone
}

func parseCredentialBrokerExpiresAt(raw string) (time.Time, bool) {
	expiresAt, err := time.Parse(time.RFC3339, strings.TrimSpace(raw))
	if err != nil {
		return time.Time{}, false
	}
	return expiresAt, true
}

func (e *pluginExecution) logPluginHostHTTPFailure(err error, reqURL *url.URL, method string, reason string) {
	if e == nil || e.manager == nil || err == nil || reqURL == nil {
		return
	}

	e.manager.logger.Warn().
		Err(err).
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Str("method", method).
		Str("scheme", reqURL.Scheme).
		Str("host", reqURL.Hostname()).
		Str("reason", reason).
		Msg("Plugin host HTTP request failed")
}

func (e *pluginExecution) logPluginHostHTTPDenied(err error, reqURL *url.URL, method string) {
	if e == nil || e.manager == nil || err == nil || reqURL == nil {
		return
	}

	e.manager.logger.Warn().
		Err(err).
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Str("method", method).
		Str("scheme", reqURL.Scheme).
		Str("host", reqURL.Hostname()).
		Str("path", reqURL.EscapedPath()).
		Msg("Plugin host HTTP request denied by credential broker grant policy")
}

func decodeBody(payload httpRequestPayload) ([]byte, error) {
	if payload.BodyBase64 != "" {
		return base64.StdEncoding.DecodeString(payload.BodyBase64)
	}
	if payload.Body != "" {
		return []byte(payload.Body), nil
	}
	return nil, nil
}

func pluginHTTPClient(base *http.Client, insecureSkipVerify bool, timeout time.Duration) *http.Client {
	client := http.DefaultClient
	if base != nil {
		client = base
	}

	cloned := *client
	cloned.Timeout = timeout

	if !insecureSkipVerify {
		return &cloned
	}

	cloned.Transport = pluginHTTPInsecureTransport(cloned.Transport)

	return &cloned
}

func pluginHTTPInsecureTransport(transport http.RoundTripper) http.RoundTripper {
	baseTransport, ok := transport.(*http.Transport)
	if transport != nil && (!ok || baseTransport == nil) {
		// An explicit custom transport owns its TLS and denial policy. Replacing
		// it with the process default would bypass wrappers such as the
		// fail-closed transport installed when configured CA roots cannot load.
		return transport
	}
	if baseTransport == nil {
		baseTransport, ok = http.DefaultTransport.(*http.Transport)
		if !ok || baseTransport == nil {
			baseTransport = &http.Transport{}
		}
	}

	pluginHTTPInsecureTransportMu.Lock()
	defer pluginHTTPInsecureTransportMu.Unlock()

	if cached := pluginHTTPInsecureTransportCache[baseTransport]; cached != nil {
		return cached
	}

	httpTransport := baseTransport.Clone()
	if httpTransport.TLSClientConfig != nil {
		httpTransport.TLSClientConfig = httpTransport.TLSClientConfig.Clone()
	} else {
		httpTransport.TLSClientConfig = &tls.Config{}
	}
	httpTransport.TLSClientConfig.InsecureSkipVerify = true //nolint:gosec
	pluginHTTPInsecureTransportCache[baseTransport] = httpTransport

	return httpTransport
}

func flattenHeaders(headers http.Header) map[string]string {
	if len(headers) == 0 {
		return nil
	}

	flat := make(map[string]string, len(headers))
	for key, values := range headers {
		if len(values) == 0 {
			continue
		}
		flat[key] = strings.Join(values, ",")
	}
	return flat
}
