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
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
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
	Method              string                     `json:"method"`
	URL                 string                     `json:"url"`
	Headers             map[string]string          `json:"headers"`
	Body                string                     `json:"body"`
	BodyBase64          string                     `json:"body_base64"`
	ResponseMode        string                     `json:"response_mode"`
	TimeoutMS           int                        `json:"timeout_ms"`
	InsecureSkipVerify  bool                       `json:"insecure_skip_verify"`
	CredentialInjection *credentialInjectionIntent `json:"credential_injection,omitempty"`
}

// credentialInjectionIntent is guest-selected authority, not credential
// material. Notification SDKs attach it only when a request intends host-side
// authentication. An absent intent must never cause a notification credential
// to be injected merely because its host ACL happens to match.
type credentialInjectionIntent struct {
	Mode                string `json:"mode"`
	Name                string `json:"name,omitempty"`
	Scheme              string `json:"scheme,omitempty"`
	GrantID             string `json:"grant_id,omitempty"`
	CredentialSecretRef string `json:"credential_secret_ref,omitempty"`
}

type httpResponsePayload struct {
	Status       int               `json:"status"`
	Headers      map[string]string `json:"headers,omitempty"`
	BodyBase64   string            `json:"body_base64"`
	BodyEncoding string            `json:"body_encoding,omitempty"`
}

const (
	httpScheme  = "http"
	httpsScheme = "https"
)

const (
	pluginHTTPDeniedReasonCredentialPolicy = "credential_broker_grant_policy"
	pluginHTTPDeniedReasonEgress           = "manifest_egress_policy"
	pluginHTTPDeniedReasonEgressHost       = "manifest_egress_policy_host"
	pluginHTTPDeniedReasonEgressPort       = "manifest_egress_policy_port"
)

var errPluginHTTPTooManyRedirects = errors.New("stopped after 10 redirects")

var (
	errPluginHostAuthorityNoPeerCertificate   = errors.New("server presented no certificate")
	errPluginHostAuthorityFingerprintMismatch = errors.New("server certificate fingerprint does not match pinned fingerprint")
)

// The insecure transport cache preserves connection reuse for the explicit
// plugin-level insecure TLS opt-in while keeping base client transports immutable.
//
//nolint:gochecknoglobals
var (
	pluginHTTPInsecureTransportMu    sync.Mutex
	pluginHTTPInsecureTransportCache = map[*http.Transport]*http.Transport{}

	pluginHTTPPinnedTransportMu    sync.Mutex
	pluginHTTPPinnedTransportCache = map[pluginHTTPPinnedTransportKey]*http.Transport{}
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
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}
	if !pluginHTTPRequestDestinationAllowed(&e.assignment.Permissions, reqURL) &&
		!pluginHostAuthorityDestinationAllowed(&e.assignment.Permissions, reqURL, proxmoxBinding) {
		e.logPluginHostHTTPDenied(
			nil,
			reqURL,
			method,
			pluginHTTPEgressDeniedReason(&e.assignment.Permissions, reqURL),
		)
		return pluginErrDenied
	}

	grant, err := e.credentialBrokerGrantForHTTP(method, reqURL, payload.CredentialInjection)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}

	rewrittenBody, err := e.rewriteAWXCallbackCredentialBody(method, reqURL, pluginBody)
	if err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
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
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}
	defer clear(authorizedBody)
	if err := e.reserveCredentialBrokerMutation(grant, method); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
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
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}
	if err := e.applyProxmoxHostAuthorityCredential(ctx, httpReq, proxmoxBinding); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}
	hostCredentialBound = hostCredentialBound || proxmoxBinding != nil

	if err := e.applyCredentialBrokerInjection(ctx, httpReq, grant, payload.InsecureSkipVerify); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}

	httpClient := pluginHTTPClientForBinding(
		e.manager.httpClient,
		payload.InsecureSkipVerify,
		timeout,
		proxmoxBinding,
	)
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

	return e.writePluginHTTPResponse(mod, resp, payload, method, respPtr, respLen, proxmoxBinding, reqURL)
}

func (e *pluginExecution) writePluginHTTPResponse(
	mod api.Module,
	resp *http.Response,
	payload httpRequestPayload,
	method string,
	respPtr uint32,
	respLen uint32,
	proxmoxBinding *pluginHostAuthorityBinding,
	reqURL *url.URL,
) int32 {
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
	case httpScheme:
		defaultPort = 80
	case httpsScheme:
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
	credentialBackedGrant := grant != nil && len(grant.Inject) > 0
	if client == nil {
		return
	}

	// A broker grant is authorized for one canonical request. Go's redirect
	// handling does not re-enter the plugin host boundary, so following even a
	// same-host redirect would bypass the grant's method/path/port checks.
	if strictAWXGrant || credentialBackedGrant || awxCredentialEndpoint(requestURL) ||
		awxReviewedCredentialTypeEndpoint(requestURL) {
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
			return errPluginHTTPTooManyRedirects
		}
		return nil
	}
}

func (e *pluginExecution) credentialBrokerGrantForHTTP(
	method string,
	reqURL *url.URL,
	intent *credentialInjectionIntent,
) (*credentialBrokerGrant, error) {
	if e == nil || e.mode != pluginExecutionModeAction {
		return nil, nil
	}
	if len(e.credentialGrants) == 0 {
		if intent != nil {
			return nil, errCredentialBrokerGrantDenied
		}
		return nil, nil
	}

	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}

	return pluginActionGrantForHTTPRequestIntent(e.credentialGrants, method, reqURL, now, intent)
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
	if shape, ok := oauth2GrantShapeFor(grant.Inject["type"]); ok {
		return e.applyCredentialBrokerOAuth2Bearer(ctx, req, *grant, material, shape, insecureSkipVerify)
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

// A manifest egress denial carries no error, so reason is what tells the two
// denial families apart and, for the egress policy, which half of it refused.
func (e *pluginExecution) logPluginHostHTTPDenied(err error, reqURL *url.URL, method, reason string) {
	if e == nil || e.manager == nil || reqURL == nil {
		return
	}

	event := e.manager.logger.Warn().
		Err(err).
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Str("method", method).
		Str("scheme", reqURL.Scheme).
		Str("host", reqURL.Hostname()).
		Str("path", reqURL.EscapedPath()).
		Str("reason", reason)
	if port, ok := pluginHTTPRequestPort(reqURL); ok {
		event = event.Int("port", port)
	}
	event.Msg("Plugin host HTTP request denied")
}

// pluginHTTPEgressDeniedReason names which half of the manifest egress policy
// refused the destination. A literal IP fails the host gate unless the manifest
// declares allowed_networks; an allowed_domains wildcard never covers one.
func pluginHTTPEgressDeniedReason(permissions *pluginPermissions, reqURL *url.URL) string {
	if permissions == nil || reqURL == nil {
		return pluginHTTPDeniedReasonEgress
	}

	port, ok := pluginHTTPRequestPort(reqURL)
	if !ok {
		// pluginHTTPRequestPort also reports !ok for a scheme it does not
		// support, which is not a port-gate failure.
		return pluginHTTPDeniedReasonEgress
	}
	if !permissions.allowsHTTPPort(port) {
		return pluginHTTPDeniedReasonEgressPort
	}

	return pluginHTTPDeniedReasonEgressHost
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

type pluginHTTPPinnedTransportKey struct {
	base        *http.Transport
	bundle      string
	fingerprint string
}

// pluginHTTPClientWithPinnedRoots returns a client that verifies against the
// binding's own trust material and nothing else. Replacing the roots rather
// than adding to them is the point: a rule that pins a private CA is asking for
// that anchor, and keeping the public roots would still accept any
// publicly-trusted certificate for the same origin.
//
// A bundle that does not parse yields the client unchanged, so verification
// falls back to the system pool and fails closed at handshake rather than
// silently trusting nothing. The control plane rejects unparseable material at
// save time, so reaching that branch means the binding was tampered with in
// transit.
// pluginHTTPClientForBinding applies the binding's own trust material when it
// carries any, so hostHTTPRequest states the intent once rather than branching
// on it inline.
func pluginHTTPClientForBinding(
	base *http.Client,
	insecureSkipVerify bool,
	timeout time.Duration,
	binding *pluginHostAuthorityBinding,
) *http.Client {
	client := pluginHTTPClient(base, insecureSkipVerify, timeout)
	if binding == nil {
		return client
	}
	if binding.caBundlePEM != "" {
		return pluginHTTPClientWithPinnedRoots(client, binding.caBundlePEM)
	}
	if binding.serverCertFingerprint != "" {
		return pluginHTTPClientWithPinnedFingerprint(client, binding.serverCertFingerprint)
	}

	return client
}

func pluginHTTPClientWithPinnedFingerprint(client *http.Client, fingerprint string) *http.Client {
	if client == nil || fingerprint == "" {
		return client
	}

	cloned := *client
	cloned.Transport = pluginHTTPPinnedFingerprintTransport(cloned.Transport, fingerprint)
	return &cloned
}

func pluginHTTPPinnedFingerprintTransport(transport http.RoundTripper, fingerprint string) http.RoundTripper {
	return pluginHTTPPinnedTransport(
		transport,
		pluginHTTPPinnedTransportKey{fingerprint: fingerprint},
		func(tlsConfig *tls.Config) {
			// Chain building and hostname matching cannot succeed without an
			// anchor; VerifyPeerCertificate is the whole verification here and
			// accepts exactly one leaf.
			tlsConfig.InsecureSkipVerify = true
			tlsConfig.VerifyPeerCertificate = func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
				return matchPluginHostAuthorityFingerprint(rawCerts, fingerprint)
			}
		},
	)
}

func matchPluginHostAuthorityFingerprint(rawCerts [][]byte, expected string) error {
	if len(rawCerts) == 0 {
		return errPluginHostAuthorityNoPeerCertificate
	}

	sum := sha256.Sum256(rawCerts[0])
	got := "sha256:" + hex.EncodeToString(sum[:])
	if got != expected {
		return fmt.Errorf("%w: got %s want %s", errPluginHostAuthorityFingerprintMismatch, got, expected)
	}
	return nil
}

func pluginHTTPClientWithPinnedRoots(client *http.Client, bundle string) *http.Client {
	pool := pluginHostAuthorityCertPool(bundle)
	if pool == nil {
		return client
	}

	cloned := *client
	cloned.Transport = pluginHTTPPinnedRootsTransport(cloned.Transport, bundle, pool)

	return &cloned
}

func pluginHTTPPinnedRootsTransport(
	transport http.RoundTripper,
	bundle string,
	pool *x509.CertPool,
) http.RoundTripper {
	return pluginHTTPPinnedTransport(
		transport,
		pluginHTTPPinnedTransportKey{bundle: bundle},
		func(tlsConfig *tls.Config) { tlsConfig.RootCAs = pool },
	)
}

// pluginHTTPPinnedTransport returns a transport whose TLS config is the base
// transport's with the binding's pinning applied. Results are memoized on the
// base transport plus the pinned material so a binding keeps one connection
// pool across requests instead of handshaking anew for every call and leaking
// an idle connection per discarded transport. `key.base` is filled in here;
// callers supply only the material that distinguishes their pinning.
func pluginHTTPPinnedTransport(
	transport http.RoundTripper,
	key pluginHTTPPinnedTransportKey,
	pin func(*tls.Config),
) http.RoundTripper {
	baseTransport, ok := transport.(*http.Transport)
	if transport != nil && (!ok || baseTransport == nil) {
		// A custom transport owns its own TLS and denial policy; replacing it
		// would bypass wrappers such as the fail-closed transport installed
		// when configured CA roots cannot load.
		return transport
	}
	if baseTransport == nil {
		baseTransport, ok = http.DefaultTransport.(*http.Transport)
		if !ok || baseTransport == nil {
			baseTransport = &http.Transport{}
		}
	}

	key.base = baseTransport

	pluginHTTPPinnedTransportMu.Lock()
	defer pluginHTTPPinnedTransportMu.Unlock()

	if cached := pluginHTTPPinnedTransportCache[key]; cached != nil {
		return cached
	}

	httpTransport := baseTransport.Clone()
	if httpTransport.TLSClientConfig != nil {
		httpTransport.TLSClientConfig = httpTransport.TLSClientConfig.Clone()
	} else {
		httpTransport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	pin(httpTransport.TLSClientConfig)
	pluginHTTPPinnedTransportCache[key] = httpTransport

	return httpTransport
}
