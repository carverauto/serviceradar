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
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tetratelabs/wazero/api"

	"github.com/carverauto/serviceradar/go/pkg/tlsclient"
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
	FollowRedirects     *bool                      `json:"follow_redirects,omitempty"`
	ConditionalETag     bool                       `json:"conditional_etag,omitempty"`
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
	SetCookies   []string          `json:"set_cookies,omitempty"`
	BodyBase64   string            `json:"body_base64"`
	BodyEncoding string            `json:"body_encoding,omitempty"`
	Trace        *httpTracePayload `json:"trace,omitempty"`
	TLS          *httpTLSPayload   `json:"tls,omitempty"`
}

type httpHopTracePayload struct {
	URL                    string `json:"url"`
	Status                 int    `json:"status"`
	DNSDurationNS          int64  `json:"dns_duration_ns"`
	ConnectDurationNS      int64  `json:"connect_duration_ns"`
	TLSHandshakeDurationNS int64  `json:"tls_handshake_duration_ns"`
	TTFBDurationNS         int64  `json:"ttfb_duration_ns"`
	RemoteAddr             string `json:"remote_addr,omitempty"`
}

type httpTracePayload struct {
	DNSDurationNS          int64                 `json:"dns_duration_ns"`
	ConnectDurationNS      int64                 `json:"connect_duration_ns"`
	TLSHandshakeDurationNS int64                 `json:"tls_handshake_duration_ns"`
	TTFBDurationNS         int64                 `json:"ttfb_duration_ns"`
	TransferDurationNS     int64                 `json:"transfer_duration_ns"`
	TotalDurationNS        int64                 `json:"total_duration_ns"`
	ConnectionReused       bool                  `json:"connection_reused"`
	RedirectCount          int                   `json:"redirect_count"`
	FinalURL               string                `json:"final_url"`
	Protocol               string                `json:"protocol,omitempty"`
	RemoteAddr             string                `json:"remote_addr,omitempty"`
	Hops                   []httpHopTracePayload `json:"hops,omitempty"`
}

type httpTLSPayload struct {
	Version           string `json:"version,omitempty"`
	CipherSuite       string `json:"cipher_suite,omitempty"`
	ALPN              string `json:"alpn,omitempty"`
	LeafSubjectCN     string `json:"leaf_subject_cn,omitempty"`
	LeafIssuerCN      string `json:"leaf_issuer_cn,omitempty"`
	LeafNotAfterUnix  *int64 `json:"leaf_not_after_unix,omitempty"`
	LeafDaysRemaining *int   `json:"leaf_days_remaining,omitempty"`
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

// pluginHTTPTransportCache memoizes the TLS variants derived from a base
// transport: the explicit plugin-level insecure opt-in, and each binding's pinned
// trust. Reusing one transport per variant keeps one connection pool across
// requests instead of handshaking anew for every call and leaking an idle
// connection per discarded transport, while base client transports stay
// immutable. The zero value is ready to use.
type pluginHTTPTransportCache struct {
	mu         sync.Mutex
	transports map[pluginHTTPTransportKey]*http.Transport
}

const (
	pluginHTTPETagMaxEntries    = 256
	pluginHTTPETagMaxValueBytes = 512
)

type pluginHTTPETagKey struct {
	assignmentID string
	url          string
}

type pluginHTTPETagEntry struct {
	etag     string
	lastUsed uint64
}

// pluginHTTPETagCache stores bounded per-(assignmentID, canonicalURL) ETag
// strings (never response bodies) so stateless Wasm plugins can opt into
// conditional GET / 304 Not Modified polling across ticks.
type pluginHTTPETagCache struct {
	mu      sync.Mutex
	seq     uint64
	entries map[pluginHTTPETagKey]pluginHTTPETagEntry
}

func (c *pluginHTTPETagCache) get(assignmentID, canonicalURL string) (string, bool) {
	if c == nil || assignmentID == "" || canonicalURL == "" {
		return "", false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	key := pluginHTTPETagKey{assignmentID: assignmentID, url: canonicalURL}
	entry, ok := c.entries[key]
	if !ok || entry.etag == "" {
		return "", false
	}
	c.seq++
	entry.lastUsed = c.seq
	c.entries[key] = entry
	return entry.etag, true
}

func (c *pluginHTTPETagCache) put(assignmentID, canonicalURL, etag string) {
	if c == nil || assignmentID == "" || canonicalURL == "" {
		return
	}
	etag = strings.TrimSpace(etag)
	if etag == "" || len(etag) > pluginHTTPETagMaxValueBytes || strings.ContainsAny(etag, "\r\n\x00") {
		c.delete(assignmentID, canonicalURL)
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[pluginHTTPETagKey]pluginHTTPETagEntry)
	}
	key := pluginHTTPETagKey{assignmentID: assignmentID, url: canonicalURL}
	if _, exists := c.entries[key]; !exists && len(c.entries) >= pluginHTTPETagMaxEntries {
		var oldestKey pluginHTTPETagKey
		var oldestSeq uint64
		first := true
		for k, v := range c.entries {
			if first || v.lastUsed < oldestSeq {
				oldestKey = k
				oldestSeq = v.lastUsed
				first = false
			}
		}
		if !first {
			delete(c.entries, oldestKey)
		}
	}
	c.seq++
	c.entries[key] = pluginHTTPETagEntry{etag: etag, lastUsed: c.seq}
}

func (c *pluginHTTPETagCache) delete(assignmentID, canonicalURL string) {
	if c == nil || assignmentID == "" || canonicalURL == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.entries, pluginHTTPETagKey{assignmentID: assignmentID, url: canonicalURL})
}

func (c *pluginHTTPETagCache) deleteAssignment(assignmentID string) {
	if c == nil || assignmentID == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.entries {
		if k.assignmentID == assignmentID {
			delete(c.entries, k)
		}
	}
}

func (c *pluginHTTPETagCache) retainAssignments(activeIDs map[string]struct{}) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.entries {
		if _, ok := activeIDs[k.assignmentID]; !ok {
			delete(c.entries, k)
		}
	}
}

func (c *pluginHTTPETagCache) clear() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.entries)
}

func canonicalHTTPETagURL(reqURL *url.URL) string {
	if reqURL == nil {
		return ""
	}
	cloned := *reqURL
	cloned.Scheme = strings.ToLower(strings.TrimSpace(cloned.Scheme))
	host := strings.ToLower(strings.TrimSuffix(cloned.Hostname(), "."))
	if port := cloned.Port(); port != "" {
		defaultPort := ""
		switch cloned.Scheme {
		case httpScheme:
			defaultPort = "80"
		case httpsScheme:
			defaultPort = "443"
		}
		if port != defaultPort {
			host = net.JoinHostPort(host, port)
		}
	}
	cloned.Host = host
	cloned.Fragment = ""
	cloned.RawFragment = ""
	return cloned.String()
}

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

	httpReq, err := http.NewRequestWithContext(ctx, method, reqURL.String(), bytes.NewReader(authorizedBody))
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

	if err := e.applyCredentialBrokerInjectionWithinBudget(
		ctx,
		httpReq,
		grant,
		payload.InsecureSkipVerify,
		timeout,
	); err != nil {
		e.logPluginHostHTTPDenied(err, reqURL, method, pluginHTTPDeniedReasonCredentialPolicy)
		return pluginErrDenied
	}

	envelopeMode := strings.EqualFold(strings.TrimSpace(payload.ResponseMode), "envelope")

	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var trace *pluginHTTPTrace
	if envelopeMode {
		trace = newPluginHTTPTrace(reqURL)
		reqCtx = httptrace.WithClientTrace(reqCtx, trace.clientTrace())
	}
	httpReq = httpReq.WithContext(reqCtx)

	httpClient := e.manager.httpTransports.clientForBinding(
		e.manager.httpClient,
		payload.InsecureSkipVerify,
		timeout,
		proxmoxBinding,
	)
	configurePluginHTTPRedirects(httpClient, grant, reqURL, &e.assignment.Permissions)
	applyPluginHTTPRedirectPolicy(httpClient, hostCredentialBound, payload.FollowRedirects, envelopeMode, trace)
	if proxmoxBinding != nil {
		if err := e.ensureActiveProxmoxAssignment(reqCtx); err != nil {
			return pluginErrDenied
		}
	}
	if trace != nil {
		trace.markStart()
	}

	var conditionalETagURL string
	if payload.ConditionalETag && method == http.MethodGet &&
		strings.TrimSpace(httpReq.Header.Get("If-None-Match")) == "" &&
		e.manager != nil && e.assignment != nil && e.assignment.AssignmentID != "" {
		conditionalETagURL = canonicalHTTPETagURL(reqURL)
		if cachedETag, ok := e.manager.httpETags.get(e.assignment.AssignmentID, conditionalETagURL); ok {
			httpReq.Header.Set("If-None-Match", cachedETag)
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
	e.invalidateRejectedOAuth2Token(httpReq, grant, resp.StatusCode)

	if conditionalETagURL != "" {
		switch {
		case resp.StatusCode == http.StatusNotModified:
			if etag := strings.TrimSpace(resp.Header.Get("ETag")); etag != "" {
				e.manager.httpETags.put(e.assignment.AssignmentID, conditionalETagURL, etag)
			}
		case resp.StatusCode >= 200 && resp.StatusCode < 300:
			if etag := strings.TrimSpace(resp.Header.Get("ETag")); etag != "" {
				e.manager.httpETags.put(e.assignment.AssignmentID, conditionalETagURL, etag)
			} else {
				e.manager.httpETags.delete(e.assignment.AssignmentID, conditionalETagURL)
			}
		case resp.StatusCode >= 400:
			e.manager.httpETags.delete(e.assignment.AssignmentID, conditionalETagURL)
		}
	}

	return e.writePluginHTTPResponse(mod, resp, payload, method, respPtr, respLen, proxmoxBinding, reqURL, trace)
}

// applyPluginHTTPRedirectPolicy layers the per-request redirect rules on top
// of the egress and credential-broker guards configurePluginHTTPRedirects
// installed.
func applyPluginHTTPRedirectPolicy(
	httpClient *http.Client,
	hostCredentialBound bool,
	followRedirects *bool,
	envelopeMode bool,
	trace *pluginHTTPTrace,
) {
	if hostCredentialBound || (followRedirects != nil && !*followRedirects) {
		// Host-retained credentials are authorized for this one canonical
		// request. Redirect handling does not re-enter the host credential gate,
		// so never replay the bearer, including to a same-origin location.
		// Guests may also explicitly opt out via follow_redirects: false.
		httpClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}
	if envelopeMode {
		stopRedirectsAtSetCookie(httpClient)
	}
	stopRedirectsReplayingGuestData(httpClient)
	if trace != nil {
		trace.wrapCheckRedirect(httpClient)
	}
}

// applyCredentialBrokerInjectionWithinBudget runs credential injection (which
// may be a slow OAuth token exchange) on its own deadline, never shorter than
// the default HTTP timeout, so the upstream request that follows starts with
// its full timeout instead of what the exchange left over.
func (e *pluginExecution) applyCredentialBrokerInjectionWithinBudget(
	ctx context.Context,
	req *http.Request,
	grant *credentialBrokerGrant,
	insecureSkipVerify bool,
	requestTimeout time.Duration,
) error {
	exchangeCtx, cancel := context.WithTimeout(ctx, max(pluginDefaultHTTPTimeout, requestTimeout))
	defer cancel()
	return e.applyCredentialBrokerInjection(exchangeCtx, req, grant, insecureSkipVerify)
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
	trace *pluginHTTPTrace,
) int32 {
	bodyReadStart := time.Now()
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
	if strings.EqualFold(strings.TrimSpace(payload.ResponseMode), "envelope") {
		responsePayload.SetCookies = cloneHeaderValues(resp.Header, "Set-Cookie")
		if trace != nil {
			responsePayload.Trace = trace.finishAndBuild(resp, bodyReadStart)
		}
		responsePayload.TLS = buildPluginHTTPTLS(resp.TLS, time.Now().UTC())
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
	if key == "" && grant.ResolveBindingID != "" {
		key = "binding:" + grant.ResolveAssignmentID + ":" + grant.ResolveBindingID
	}
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

func (c *pluginHTTPTransportCache) client(base *http.Client, insecureSkipVerify bool, timeout time.Duration) *http.Client {
	client := http.DefaultClient
	if base != nil {
		client = base
	}

	cloned := *client
	cloned.Timeout = timeout

	if !insecureSkipVerify {
		return &cloned
	}

	cloned.Transport = c.insecureTransport(cloned.Transport)

	return &cloned
}

func (c *pluginHTTPTransportCache) insecureTransport(transport http.RoundTripper) http.RoundTripper {
	return c.derivedTransport(transport, pluginHTTPTransportKey{insecure: true}, func(base *tls.Config) *tls.Config {
		// The variant is cached per base transport, so this logs once per
		// pool rather than once per request.
		return tlsclient.Config(tlsclient.Policy{
			Base:               base,
			InsecureSkipVerify: true,
			OptIn:              "http_request.insecure_skip_verify",
			Target:             "plugin http_request",
		})
	})
}

// tlsSkipLogger returns the plugin manager's logger scoped to this
// assignment, for the warning tlsclient writes when a guest opts out of
// certificate verification.
func (e *pluginExecution) tlsSkipLogger() tlsclient.Warner {
	if e == nil || e.manager == nil || e.manager.logger == nil {
		return nil
	}

	scoped := e.manager.logger.With().
		Str("assignment_id", e.assignment.AssignmentID).
		Str("plugin_id", e.assignment.PluginID).
		Logger()

	return &scoped
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

// pluginHTTPTransportKey identifies one TLS variant of a base transport.
type pluginHTTPTransportKey struct {
	base        *http.Transport
	insecure    bool
	bundle      string
	fingerprint string
}

// clientForBinding applies the binding's own trust material when it
// carries any, so hostHTTPRequest states the intent once rather than branching
// on it inline.
func (c *pluginHTTPTransportCache) clientForBinding(
	base *http.Client,
	insecureSkipVerify bool,
	timeout time.Duration,
	binding *pluginHostAuthorityBinding,
) *http.Client {
	client := c.client(base, insecureSkipVerify, timeout)
	if binding == nil {
		return client
	}
	if binding.caBundlePEM != "" {
		return c.clientWithPinnedRoots(client, binding.caBundlePEM)
	}
	if binding.serverCertFingerprint != "" {
		return c.clientWithPinnedFingerprint(client, binding.serverCertFingerprint)
	}

	return client
}

func (c *pluginHTTPTransportCache) clientWithPinnedFingerprint(client *http.Client, fingerprint string) *http.Client {
	if client == nil || fingerprint == "" {
		return client
	}

	cloned := *client
	cloned.Transport = c.pinnedFingerprintTransport(cloned.Transport, fingerprint)
	return &cloned
}

func (c *pluginHTTPTransportCache) pinnedFingerprintTransport(transport http.RoundTripper, fingerprint string) http.RoundTripper {
	return c.derivedTransport(
		transport,
		pluginHTTPTransportKey{fingerprint: fingerprint},
		func(base *tls.Config) *tls.Config {
			// The fingerprint match is the whole verification and accepts
			// exactly one leaf.
			return tlsclient.Config(tlsclient.Policy{Base: base, PinnedFingerprint: fingerprint})
		},
	)
}

// clientWithPinnedRoots returns a client that verifies against the
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
func (c *pluginHTTPTransportCache) clientWithPinnedRoots(client *http.Client, bundle string) *http.Client {
	pool := pluginHostAuthorityCertPool(bundle)
	if pool == nil {
		return client
	}

	cloned := *client
	cloned.Transport = c.pinnedRootsTransport(cloned.Transport, bundle, pool)

	return &cloned
}

func (c *pluginHTTPTransportCache) pinnedRootsTransport(
	transport http.RoundTripper,
	bundle string,
	pool *x509.CertPool,
) http.RoundTripper {
	return c.derivedTransport(
		transport,
		pluginHTTPTransportKey{bundle: bundle},
		func(base *tls.Config) *tls.Config {
			return tlsclient.Config(tlsclient.Policy{Base: base, PinnedRoots: pool})
		},
	)
}

// derivedTransport returns a transport whose TLS config is the base
// transport's with configure applied: the insecure opt-in or a binding's
// pinning. Results are memoized on the base transport plus the variant so a
// binding keeps one connection pool across requests instead of handshaking anew
// for every call and leaking an idle connection per discarded transport.
// `key.base` is filled in here; callers supply only what distinguishes their
// variant.
func (c *pluginHTTPTransportCache) derivedTransport(
	transport http.RoundTripper,
	key pluginHTTPTransportKey,
	configure func(*tls.Config) *tls.Config,
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

	c.mu.Lock()
	defer c.mu.Unlock()

	if cached := c.transports[key]; cached != nil {
		return cached
	}

	httpTransport := baseTransport.Clone()
	// configure builds the variant from the base config through tlsclient,
	// which clones it; a nil base starts from tlsclient's TLS 1.2 default.
	httpTransport.TLSClientConfig = configure(httpTransport.TLSClientConfig)
	if c.transports == nil {
		c.transports = make(map[pluginHTTPTransportKey]*http.Transport)
	}
	c.transports[key] = httpTransport

	return httpTransport
}

const pluginHTTPMaxTraceHops = 11

type pluginHTTPTraceHop struct {
	url              string
	status           int
	dnsNS            int64
	connectNS        int64
	tlsNS            int64
	ttfbNS           int64
	connectionReused bool
	remoteAddr       string
	wroteRequestAt   time.Time
	firstByteAt      time.Time
}

type pluginHTTPTrace struct {
	mu            sync.Mutex
	requestStart  time.Time
	dnsStart      time.Time
	tlsStart      time.Time
	connectStarts map[string]time.Time
	hops          []pluginHTTPTraceHop
	redirectCount int
}

func newPluginHTTPTrace(initialURL *url.URL) *pluginHTTPTrace {
	return &pluginHTTPTrace{
		connectStarts: make(map[string]time.Time),
		hops: []pluginHTTPTraceHop{
			{url: scrubPluginTraceURL(initialURL)},
		},
	}
}

func (t *pluginHTTPTrace) markStart() {
	if t == nil {
		return
	}
	t.mu.Lock()
	t.requestStart = time.Now()
	t.mu.Unlock()
}

func (t *pluginHTTPTrace) activeHopLocked() *pluginHTTPTraceHop {
	if len(t.hops) == 0 {
		t.hops = append(t.hops, pluginHTTPTraceHop{})
	}
	return &t.hops[len(t.hops)-1]
}

func (t *pluginHTTPTrace) clientTrace() *httptrace.ClientTrace {
	return &httptrace.ClientTrace{
		DNSStart: func(_ httptrace.DNSStartInfo) {
			t.mu.Lock()
			t.dnsStart = time.Now()
			t.mu.Unlock()
		},
		DNSDone: func(info httptrace.DNSDoneInfo) {
			t.mu.Lock()
			if !t.dnsStart.IsZero() && info.Err == nil {
				t.activeHopLocked().dnsNS += max(0, time.Since(t.dnsStart).Nanoseconds())
			}
			t.dnsStart = time.Time{}
			t.mu.Unlock()
		},
		ConnectStart: func(network, addr string) {
			t.mu.Lock()
			if t.connectStarts == nil {
				t.connectStarts = make(map[string]time.Time)
			}
			t.connectStarts[network+"\x00"+addr] = time.Now()
			t.mu.Unlock()
		},
		ConnectDone: func(network, addr string, err error) {
			key := network + "\x00" + addr
			t.mu.Lock()
			start, ok := t.connectStarts[key]
			delete(t.connectStarts, key)
			if ok && err == nil {
				t.activeHopLocked().connectNS += max(0, time.Since(start).Nanoseconds())
			}
			t.mu.Unlock()
		},
		TLSHandshakeStart: func() {
			t.mu.Lock()
			t.tlsStart = time.Now()
			t.mu.Unlock()
		},
		TLSHandshakeDone: func(_ tls.ConnectionState, err error) {
			t.mu.Lock()
			if !t.tlsStart.IsZero() && err == nil {
				t.activeHopLocked().tlsNS += max(0, time.Since(t.tlsStart).Nanoseconds())
			}
			t.tlsStart = time.Time{}
			t.mu.Unlock()
		},
		GotConn: func(info httptrace.GotConnInfo) {
			t.mu.Lock()
			hop := t.activeHopLocked()
			hop.connectionReused = info.Reused
			if info.Conn != nil && info.Conn.RemoteAddr() != nil {
				hop.remoteAddr = info.Conn.RemoteAddr().String()
			}
			t.mu.Unlock()
		},
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			if info.Err != nil {
				return
			}
			t.mu.Lock()
			t.activeHopLocked().wroteRequestAt = time.Now()
			t.mu.Unlock()
		},
		GotFirstResponseByte: func() {
			now := time.Now()
			t.mu.Lock()
			hop := t.activeHopLocked()
			hop.firstByteAt = now
			if !hop.wroteRequestAt.IsZero() {
				hop.ttfbNS = max(0, now.Sub(hop.wroteRequestAt).Nanoseconds())
			}
			t.mu.Unlock()
		},
	}
}

// stopRedirectsAtSetCookie returns a redirect response that sets cookies to the
// guest instead of following it, because the host client keeps no cookie jar.
func stopRedirectsAtSetCookie(client *http.Client) {
	if client == nil {
		return
	}
	previous := client.CheckRedirect
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if req != nil && req.Response != nil && len(req.Response.Header.Values("Set-Cookie")) > 0 {
			return http.ErrUseLastResponse
		}
		if previous != nil {
			return previous(req, via)
		}
		return nil
	}
}

// stopRedirectsReplayingGuestData refuses a cross-host hop that would resend
// the guest's request body or a guest header outside a small safe set, and
// strips the query and fragment from the Referer of every hop still followed.
func stopRedirectsReplayingGuestData(client *http.Client) {
	if client == nil {
		return
	}
	previous := client.CheckRedirect
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if req != nil && len(via) > 0 && via[0] != nil && via[0].URL != nil && req.URL != nil &&
			!pluginHTTPRedirectSameHost(req.URL, via[0].URL) &&
			(pluginHTTPRedirectCarriesBody(req) || pluginHTTPRequestHasUnsafeHeader(via[0])) {
			return http.ErrUseLastResponse
		}
		if previous != nil {
			if err := previous(req, via); err != nil {
				return err
			}
		} else if len(via) >= 10 {
			return errPluginHTTPTooManyRedirects
		}
		if req != nil {
			if referer := req.Header.Get("Referer"); referer != "" {
				parsed, err := url.Parse(referer)
				if err != nil {
					req.Header.Del("Referer")
				} else {
					req.Header.Set("Referer", scrubPluginTraceURL(parsed))
				}
			}
		}
		return nil
	}
}

func pluginHTTPRedirectSameHost(next, origin *url.URL) bool {
	if strings.EqualFold(next.Host, origin.Host) {
		return true
	}
	return pluginHTTPCanonicalHostPort(next) == pluginHTTPCanonicalHostPort(origin)
}

func pluginHTTPCanonicalHostPort(u *url.URL) string {
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	port := u.Port()
	scheme := strings.ToLower(u.Scheme)
	if (scheme == "https" && port == "443") || (scheme == "http" && port == "80") {
		port = ""
	}
	return net.JoinHostPort(host, port)
}

func pluginHTTPRedirectCarriesBody(req *http.Request) bool {
	return req.ContentLength != 0 || (req.Body != nil && req.Body != http.NoBody)
}

func pluginHTTPRequestHasUnsafeHeader(req *http.Request) bool {
	for name := range req.Header {
		if !pluginHTTPCrossHostRedirectSafeHeader(http.CanonicalHeaderKey(name)) {
			return true
		}
	}
	return false
}

// pluginHTTPCrossHostRedirectSafeHeader reports whether a canonical header
// name may be replayed on a cross-host redirect hop.
func pluginHTTPCrossHostRedirectSafeHeader(name string) bool {
	switch name {
	case "Accept", "Accept-Encoding", "Accept-Language", "Cache-Control",
		"Content-Type", "Pragma", "User-Agent":
		return true
	default:
		return false
	}
}

func (t *pluginHTTPTrace) wrapCheckRedirect(client *http.Client) {
	if t == nil || client == nil {
		return
	}
	previous := client.CheckRedirect
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if previous != nil {
			if err := previous(req, via); err != nil {
				return err
			}
		} else if len(via) >= 10 {
			return errPluginHTTPTooManyRedirects
		}

		t.mu.Lock()
		hop := t.activeHopLocked()
		if len(via) > 0 && via[len(via)-1] != nil && via[len(via)-1].URL != nil {
			hop.url = scrubPluginTraceURL(via[len(via)-1].URL)
		}
		if req != nil && req.Response != nil {
			hop.status = req.Response.StatusCode
		}
		t.redirectCount++
		t.dnsStart = time.Time{}
		t.tlsStart = time.Time{}
		t.connectStarts = make(map[string]time.Time)
		if len(t.hops) < pluginHTTPMaxTraceHops {
			nextURL := ""
			if req != nil {
				nextURL = scrubPluginTraceURL(req.URL)
			}
			t.hops = append(t.hops, pluginHTTPTraceHop{url: nextURL})
		}
		t.mu.Unlock()

		return nil
	}
}

func (t *pluginHTTPTrace) finishAndBuild(resp *http.Response, bodyReadStart time.Time) *httpTracePayload {
	if t == nil {
		return nil
	}
	now := time.Now()

	t.mu.Lock()
	defer t.mu.Unlock()

	finalURL := ""
	if resp != nil && resp.Request != nil && resp.Request.URL != nil {
		finalURL = scrubPluginTraceURL(resp.Request.URL)
	}
	if len(t.hops) > 0 {
		last := &t.hops[len(t.hops)-1]
		if resp != nil {
			last.status = resp.StatusCode
		}
		if finalURL != "" {
			last.url = finalURL
		} else {
			finalURL = last.url
		}
	}

	var totalNS int64
	if !t.requestStart.IsZero() {
		totalNS = max(0, now.Sub(t.requestStart).Nanoseconds())
	}

	var transferNS int64
	if len(t.hops) > 0 && !t.hops[len(t.hops)-1].firstByteAt.IsZero() {
		transferNS = max(0, now.Sub(t.hops[len(t.hops)-1].firstByteAt).Nanoseconds())
	} else if !bodyReadStart.IsZero() {
		transferNS = max(0, now.Sub(bodyReadStart).Nanoseconds())
	}

	var dnsNS, connectNS, tlsNS int64
	hops := make([]httpHopTracePayload, 0, len(t.hops))
	for _, h := range t.hops {
		dnsNS += h.dnsNS
		connectNS += h.connectNS
		tlsNS += h.tlsNS
		hops = append(hops, httpHopTracePayload{
			URL:                    h.url,
			Status:                 h.status,
			DNSDurationNS:          h.dnsNS,
			ConnectDurationNS:      h.connectNS,
			TLSHandshakeDurationNS: h.tlsNS,
			TTFBDurationNS:         h.ttfbNS,
			RemoteAddr:             h.remoteAddr,
		})
	}

	var ttfbNS int64
	var reused bool
	var remoteAddr string
	if len(t.hops) > 0 {
		last := t.hops[len(t.hops)-1]
		ttfbNS = last.ttfbNS
		reused = last.connectionReused
		remoteAddr = last.remoteAddr
	}

	protocol := ""
	if resp != nil {
		protocol = resp.Proto
	}

	return &httpTracePayload{
		DNSDurationNS:          dnsNS,
		ConnectDurationNS:      connectNS,
		TLSHandshakeDurationNS: tlsNS,
		TTFBDurationNS:         ttfbNS,
		TransferDurationNS:     transferNS,
		TotalDurationNS:        totalNS,
		ConnectionReused:       reused,
		RedirectCount:          t.redirectCount,
		FinalURL:               finalURL,
		Protocol:               protocol,
		RemoteAddr:             remoteAddr,
		Hops:                   hops,
	}
}

func scrubPluginTraceURL(raw *url.URL) string {
	if raw == nil {
		return ""
	}
	clone := *raw
	clone.User = nil
	clone.RawQuery = ""
	clone.ForceQuery = false
	clone.Fragment = ""
	clone.RawFragment = ""
	return clone.String()
}

func buildPluginHTTPTLS(state *tls.ConnectionState, now time.Time) *httpTLSPayload {
	if state == nil {
		return nil
	}

	var version string
	switch state.Version {
	case tls.VersionTLS13:
		version = "TLS1.3"
	case tls.VersionTLS12:
		version = "TLS1.2"
	case tls.VersionTLS11:
		version = "TLS1.1"
	case tls.VersionTLS10:
		version = "TLS1.0"
	}

	var cipherSuite string
	if state.CipherSuite != 0 {
		cipherSuite = tls.CipherSuiteName(state.CipherSuite)
	}

	out := &httpTLSPayload{
		Version:     version,
		CipherSuite: cipherSuite,
		ALPN:        state.NegotiatedProtocol,
	}
	if len(state.PeerCertificates) > 0 && state.PeerCertificates[0] != nil {
		leaf := state.PeerCertificates[0]
		out.LeafSubjectCN = leaf.Subject.CommonName
		out.LeafIssuerCN = leaf.Issuer.CommonName
		notAfter := leaf.NotAfter.Unix()
		daysRemaining := int(math.Floor(leaf.NotAfter.Sub(now).Seconds() / 86400.0))
		out.LeafNotAfterUnix = &notAfter
		out.LeafDaysRemaining = &daysRemaining
	}
	return out
}

func cloneHeaderValues(headers http.Header, name string) []string {
	values := headers.Values(name)
	if len(values) == 0 {
		return nil
	}
	out := make([]string, len(values))
	copy(out, values)
	return out
}
