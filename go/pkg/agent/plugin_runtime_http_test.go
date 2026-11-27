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
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

const pluginHTTPTestStartPath = "/start"

func callPluginHostHTTPPayload(
	t *testing.T,
	exec *pluginExecution,
	mod api.Module,
	req httpRequestPayload,
) (int32, []byte) {
	t.Helper()

	payload, err := json.Marshal(req)
	require.NoError(t, err)

	const (
		requestPtr  = uint32(0)
		responsePtr = uint32(20 * 1024)
		responseLen = uint32(40 * 1024)
	)
	require.True(t, mod.Memory().Write(requestPtr, payload), "write request payload")

	n := exec.hostHTTPRequest(
		t.Context(),
		mod,
		requestPtr,
		uint32(len(payload)),
		responsePtr,
		responseLen,
	)
	if n <= 0 {
		return n, nil
	}
	raw, ok := mod.Memory().Read(responsePtr, uint32(n))
	require.True(t, ok, "read response payload")
	return n, append([]byte(nil), raw...)
}

func serverPortFromURL(t *testing.T, rawURL string) int {
	t.Helper()
	parsed, err := url.Parse(rawURL)
	require.NoError(t, err)
	port, err := strconv.Atoi(parsed.Port())
	require.NoError(t, err)
	return port
}

func boolPtr(v bool) *bool {
	return &v
}

func TestPluginHostHTTPEnvelopeColdAndReusedKeepAlive(t *testing.T) {
	t.Parallel()

	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	perms := pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}
	exec, mod := newPluginHTTPHostTestExecution(t, perms, srv.Client().Transport, nil)

	// Cold connection.
	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/health",
		ResponseMode: "envelope",
	})
	require.Positive(t, code)

	var first httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &first))
	require.Equal(t, http.StatusOK, first.Status)
	require.NotNil(t, first.Trace)
	assert.False(t, first.Trace.ConnectionReused)
	assert.Positive(t, first.Trace.ConnectDurationNS)
	assert.Positive(t, first.Trace.TLSHandshakeDurationNS)
	assert.Positive(t, first.Trace.TotalDurationNS)
	assert.GreaterOrEqual(t, first.Trace.TTFBDurationNS, int64(0))
	assert.GreaterOrEqual(t, first.Trace.TransferDurationNS, int64(0))
	assert.NotEmpty(t, first.Trace.RemoteAddr)
	assert.NotEmpty(t, first.Trace.Protocol)
	assert.Equal(t, 0, first.Trace.RedirectCount)
	require.Len(t, first.Trace.Hops, 1)
	assert.Equal(t, http.StatusOK, first.Trace.Hops[0].Status)
	assert.Equal(t, srv.URL+"/health", first.Trace.FinalURL)

	// Reused keep-alive connection on same manager.
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/health",
		ResponseMode: "envelope",
	})
	require.Positive(t, code)

	var second httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &second))
	require.NotNil(t, second.Trace)
	assert.True(t, second.Trace.ConnectionReused)
	assert.Equal(t, int64(0), second.Trace.DNSDurationNS)
	assert.Equal(t, int64(0), second.Trace.ConnectDurationNS)
	assert.Equal(t, int64(0), second.Trace.TLSHandshakeDurationNS)
	assert.Positive(t, second.Trace.TotalDurationNS)
}

func TestPluginHostHTTPEnvelopeTLSPostureAndLeafExpiry(t *testing.T) {
	t.Parallel()

	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	perms := pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}

	// Verified TLS with pinned server transport.
	exec, mod := newPluginHTTPHostTestExecution(t, perms, srv.Client().Transport, nil)
	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL,
		ResponseMode: "envelope",
	})
	require.Positive(t, code)

	var resp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &resp))
	require.NotNil(t, resp.TLS)
	assert.Contains(t, []string{"TLS1.2", "TLS1.3"}, resp.TLS.Version)
	assert.NotEmpty(t, resp.TLS.CipherSuite)
	require.NotNil(t, resp.TLS.LeafNotAfterUnix)
	require.NotNil(t, resp.TLS.LeafDaysRemaining)
	assert.GreaterOrEqual(t, *resp.TLS.LeafDaysRemaining, 0)

	// InsecureSkipVerify: true over default transport against self-signed TLS server.
	execInsecure, modInsecure := newPluginHTTPHostTestExecution(t, perms, nil, nil)
	code, raw = callPluginHostHTTPPayload(t, execInsecure, modInsecure, httpRequestPayload{
		Method:             http.MethodGet,
		URL:                srv.URL,
		ResponseMode:       "envelope",
		InsecureSkipVerify: true,
	})
	require.Positive(t, code)
	var respInsecure httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &respInsecure))
	require.NotNil(t, respInsecure.TLS)
	assert.NotEmpty(t, respInsecure.TLS.Version)

	// Plaintext HTTP omits TLS info.
	plainSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("plain"))
	}))
	defer plainSrv.Close()
	plainPort := serverPortFromURL(t, plainSrv.URL)
	execPlain, modPlain := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{plainPort},
	}, nil, nil)
	code, raw = callPluginHostHTTPPayload(t, execPlain, modPlain, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          plainSrv.URL,
		ResponseMode: "envelope",
	})
	require.Positive(t, code)
	var plainResp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &plainResp))
	assert.Nil(t, plainResp.TLS)
}

func TestBuildPluginHTTPTLSZeroAndNegativeDaysRemaining(t *testing.T) {
	t.Parallel()

	assert.Nil(t, buildPluginHTTPTLS(nil, time.Now()))

	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)

	makeCert := func(notAfter time.Time, cn string) *x509.Certificate {
		tmpl := &x509.Certificate{
			SerialNumber: big.NewInt(1),
			Subject:      pkix.Name{CommonName: cn},
			NotBefore:    now.Add(-48 * time.Hour),
			NotAfter:     notAfter,
		}
		issuer := &x509.Certificate{
			Subject: pkix.Name{CommonName: "test-ca.example.com"},
		}
		der, certErr := x509.CreateCertificate(rand.Reader, tmpl, issuer, &priv.PublicKey, priv)
		require.NoError(t, certErr)
		cert, parseErr := x509.ParseCertificate(der)
		require.NoError(t, parseErr)
		return cert
	}

	// Expires in 12 hours -> 0 days remaining, must serialize "leaf_days_remaining":0.
	expiringCert := makeCert(now.Add(12*time.Hour), "expiring.example.com")
	tlsInfo := buildPluginHTTPTLS(&tls.ConnectionState{
		Version:            tls.VersionTLS13,
		CipherSuite:        tls.TLS_AES_128_GCM_SHA256,
		NegotiatedProtocol: "h2",
		PeerCertificates:   []*x509.Certificate{expiringCert},
	}, now)
	require.NotNil(t, tlsInfo)
	assert.Equal(t, "TLS1.3", tlsInfo.Version)
	assert.Equal(t, "h2", tlsInfo.ALPN)
	assert.Equal(t, "expiring.example.com", tlsInfo.LeafSubjectCN)
	assert.Equal(t, "test-ca.example.com", tlsInfo.LeafIssuerCN)
	require.NotNil(t, tlsInfo.LeafDaysRemaining)
	assert.Equal(t, 0, *tlsInfo.LeafDaysRemaining)

	encoded, err := json.Marshal(tlsInfo)
	require.NoError(t, err)
	assert.Contains(t, string(encoded), `"leaf_days_remaining":0`)

	// Expired 36 hours ago -> -2 days remaining.
	expiredCert := makeCert(now.Add(-36*time.Hour), "expired.example.com")
	expiredInfo := buildPluginHTTPTLS(&tls.ConnectionState{
		Version:          tls.VersionTLS12,
		CipherSuite:      tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
		PeerCertificates: []*x509.Certificate{expiredCert},
	}, now)
	require.NotNil(t, expiredInfo)
	assert.Equal(t, "TLS1.2", expiredInfo.Version)
	require.NotNil(t, expiredInfo.LeafDaysRemaining)
	assert.Equal(t, -2, *expiredInfo.LeafDaysRemaining)

	// Handshake without PeerCertificates must omit leaf expiry fields rather than serializing 0.
	noLeafInfo := buildPluginHTTPTLS(&tls.ConnectionState{
		Version:            tls.VersionTLS13,
		CipherSuite:        tls.TLS_AES_128_GCM_SHA256,
		NegotiatedProtocol: "h2",
	}, now)
	require.NotNil(t, noLeafInfo)
	assert.Equal(t, "TLS1.3", noLeafInfo.Version)
	assert.Nil(t, noLeafInfo.LeafNotAfterUnix)
	assert.Nil(t, noLeafInfo.LeafDaysRemaining)

	noLeafEncoded, err := json.Marshal(noLeafInfo)
	require.NoError(t, err)
	assert.NotContains(t, string(noLeafEncoded), "leaf_not_after_unix")
	assert.NotContains(t, string(noLeafEncoded), "leaf_days_remaining")
}

func TestPluginHostHTTPEnvelopeMultiSetCookiePreserved(t *testing.T) {
	t.Parallel()

	cookie1 := "sid=alpha; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly; Secure"
	cookie2 := "csrf=beta; Path=/app; Expires=Thu, 22 Oct 2026 07:28:00 GMT; SameSite=Lax"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Set-Cookie", cookie1)
		w.Header().Add("Set-Cookie", cookie2)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	exec, mod := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}, nil, nil)

	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/login",
		ResponseMode: "envelope",
	})
	require.Positive(t, code)

	var resp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &resp))
	assert.Equal(t, []string{cookie1, cookie2}, resp.SetCookies)
	assert.Equal(t, cookie1+","+cookie2, resp.Headers["Set-Cookie"])
}

func TestPluginHostHTTPFollowRedirectsControlAndCredentialGuard(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case pluginHTTPTestStartPath:
			w.Header().Add("Set-Cookie", "step=one; Path=/")
			http.Redirect(w, r, "/next", http.StatusFound)
		case "/plain":
			http.Redirect(w, r, "/next", http.StatusFound)
		case "/next":
			_, _ = w.Write([]byte("arrived"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	perms := pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}

	// follow_redirects: false stops on 302 and returns Set-Cookie + Location.
	exec, mod := newPluginHTTPHostTestExecution(t, perms, nil, nil)
	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + pluginHTTPTestStartPath,
		ResponseMode:    "envelope",
		FollowRedirects: boolPtr(false),
	})
	require.Positive(t, code)

	var noFollowResp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &noFollowResp))
	assert.Equal(t, http.StatusFound, noFollowResp.Status)
	assert.Equal(t, "/next", noFollowResp.Headers["Location"])
	assert.Equal(t, []string{"step=one; Path=/"}, noFollowResp.SetCookies)
	require.NotNil(t, noFollowResp.Trace)
	assert.Equal(t, 0, noFollowResp.Trace.RedirectCount)
	require.Len(t, noFollowResp.Trace.Hops, 1)
	assert.Equal(t, http.StatusFound, noFollowResp.Trace.Hops[0].Status)

	// follow_redirects: true still returns a cookie-setting 302 so its
	// Set-Cookie reaches the guest instead of being dropped by the followed hop.
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + pluginHTTPTestStartPath,
		ResponseMode:    "envelope",
		FollowRedirects: boolPtr(true),
	})
	require.Positive(t, code)

	var cookieRedirectResp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &cookieRedirectResp))
	assert.Equal(t, http.StatusFound, cookieRedirectResp.Status)
	assert.Equal(t, []string{"step=one; Path=/"}, cookieRedirectResp.SetCookies)
	require.NotNil(t, cookieRedirectResp.Trace)
	assert.Equal(t, 0, cookieRedirectResp.Trace.RedirectCount)
	require.Len(t, cookieRedirectResp.Trace.Hops, 1)

	// follow_redirects: true follows a redirect that sets no cookies to /next.
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + "/plain",
		ResponseMode:    "envelope",
		FollowRedirects: boolPtr(true),
	})
	require.Positive(t, code)

	var followResp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &followResp))
	assert.Equal(t, http.StatusOK, followResp.Status)
	require.NotNil(t, followResp.Trace)
	assert.Equal(t, 1, followResp.Trace.RedirectCount)
	assert.Equal(t, srv.URL+"/next", followResp.Trace.FinalURL)
	require.Len(t, followResp.Trace.Hops, 2)
	assert.Equal(t, http.StatusFound, followResp.Trace.Hops[0].Status)
	assert.Equal(t, srv.URL+"/plain", followResp.Trace.Hops[0].URL)
	assert.Equal(t, http.StatusOK, followResp.Trace.Hops[1].Status)
	assert.Equal(t, srv.URL+"/next", followResp.Trace.Hops[1].URL)

	// Credential-backed grant refuses redirects even when follow_redirects: true.
	execCred, modCred := newPluginHTTPHostTestExecution(
		t,
		perms,
		nil,
		&fakeCredentialBrokerResolver{
			material: CredentialBrokerMaterial{Value: "secret-api-key"},
		},
	)
	execCred.mode = pluginExecutionModeAction
	execCred.credentialGrants = []credentialBrokerGrant{
		{
			GrantID:             "grant-1",
			CredentialSecretRef: "secret-1",
			Inject: map[string]string{
				"type": "http_header",
				"name": "X-API-Key",
			},
			Allow: credentialBrokerACL{
				Hosts: []string{"127.0.0.1"},
				Ports: []int{port},
			},
		},
	}
	code, raw = callPluginHostHTTPPayload(t, execCred, modCred, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + pluginHTTPTestStartPath,
		ResponseMode:    "envelope",
		FollowRedirects: boolPtr(true),
		CredentialInjection: &credentialInjectionIntent{
			Mode:    "http_header",
			Name:    "X-API-Key",
			GrantID: "grant-1",
		},
	})
	require.Positive(t, code)
	var credResp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &credResp))
	assert.Equal(t, http.StatusFound, credResp.Status)
	require.NotNil(t, credResp.Trace)
	assert.Equal(t, 0, credResp.Trace.RedirectCount)
	require.Len(t, credResp.Trace.Hops, 1)

	// Disallowed redirect destination stops at 302 without executing disallowed hop.
	disallowedSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://blocked.example.invalid/secret", http.StatusFound)
	}))
	defer disallowedSrv.Close()
	disallowedPort := serverPortFromURL(t, disallowedSrv.URL)
	execDisallowed, modDisallowed := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{disallowedPort},
	}, nil, nil)
	code, raw = callPluginHostHTTPPayload(t, execDisallowed, modDisallowed, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             disallowedSrv.URL + pluginHTTPTestStartPath,
		ResponseMode:    "envelope",
		FollowRedirects: boolPtr(true),
	})
	require.Positive(t, code)
	var deniedHopResp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &deniedHopResp))
	assert.Equal(t, http.StatusFound, deniedHopResp.Status)
	require.NotNil(t, deniedHopResp.Trace)
	assert.Equal(t, 0, deniedHopResp.Trace.RedirectCount)
	require.Len(t, deniedHopResp.Trace.Hops, 1)
}

func TestPluginHostHTTPRedirectDoesNotReplayGuestSecretsCrossHost(t *testing.T) {
	t.Parallel()

	var sinkMu sync.Mutex
	var sinkHits []*http.Request
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sinkMu.Lock()
		sinkHits = append(sinkHits, r.Clone(context.Background()))
		sinkMu.Unlock()
		_, _ = w.Write([]byte("sink"))
	}))
	defer sink.Close()

	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login":
			http.Redirect(w, r, sink.URL+"/collect", http.StatusTemporaryRedirect)
		case pluginHTTPTestStartPath:
			http.Redirect(w, r, sink.URL+"/asset", http.StatusFound)
		case "/same":
			http.Redirect(w, r, "/landing", http.StatusTemporaryRedirect)
		case "/landing":
			_, _ = w.Write([]byte(r.Method))
		default:
			http.NotFound(w, r)
		}
	}))
	defer origin.Close()

	exec, mod := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{serverPortFromURL(t, origin.URL), serverPortFromURL(t, sink.URL)},
	}, nil, nil)

	call := func(req httpRequestPayload) httpResponsePayload {
		req.ResponseMode = "envelope"
		code, raw := callPluginHostHTTPPayload(t, exec, mod, req)
		require.Positive(t, code)
		var resp httpResponsePayload
		require.NoError(t, json.Unmarshal(raw, &resp))
		return resp
	}
	sinkCount := func() int {
		sinkMu.Lock()
		defer sinkMu.Unlock()
		return len(sinkHits)
	}

	bodyResp := call(httpRequestPayload{
		Method:  http.MethodPost,
		URL:     origin.URL + "/login",
		Body:    "password=hunter2",
		Headers: map[string]string{"Content-Type": "application/x-www-form-urlencoded"},
	})
	assert.Equal(t, http.StatusTemporaryRedirect, bodyResp.Status)
	assert.Equal(t, 0, sinkCount())

	headerResp := call(httpRequestPayload{
		Method:  http.MethodGet,
		URL:     origin.URL + pluginHTTPTestStartPath,
		Headers: map[string]string{"X-API-Key": "secret-key"},
	})
	assert.Equal(t, http.StatusFound, headerResp.Status)
	assert.Equal(t, 0, sinkCount())

	plainResp := call(httpRequestPayload{
		Method:  http.MethodGet,
		URL:     origin.URL + "/start?code=top-secret#frag",
		Headers: map[string]string{"Accept": "text/html"},
	})
	assert.Equal(t, http.StatusOK, plainResp.Status)
	require.Equal(t, 1, sinkCount())
	sinkMu.Lock()
	assert.Equal(t, origin.URL+pluginHTTPTestStartPath, sinkHits[0].Header.Get("Referer"))
	sinkMu.Unlock()

	sameHostResp := call(httpRequestPayload{
		Method:  http.MethodPost,
		URL:     origin.URL + "/same",
		Body:    "payload",
		Headers: map[string]string{"X-API-Key": "secret-key"},
	})
	assert.Equal(t, http.StatusOK, sameHostResp.Status)
	body, err := base64.StdEncoding.DecodeString(sameHostResp.BodyBase64)
	require.NoError(t, err)
	assert.Equal(t, http.MethodPost, string(body))
	assert.Equal(t, 1, sinkCount())
}

func TestPluginHostHTTPRedirectQueryScrubbingAndHopCap(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/oauth/start":
			http.Redirect(w, r, "/oauth/callback?code=top-secret-code&state=xyz#access_token=abc", http.StatusFound)
		case "/oauth/callback":
			_, _ = w.Write([]byte("done"))
		case "/loop":
			nextHop := 1
			if raw := r.URL.Query().Get("n"); raw != "" {
				n, _ := strconv.Atoi(raw)
				nextHop = n + 1
			}
			http.Redirect(w, r, fmt.Sprintf("/loop?n=%d", nextHop), http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	parsed, err := url.Parse(srv.URL)
	require.NoError(t, err)
	port := serverPortFromURL(t, srv.URL)
	exec, mod := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}, nil, nil)

	startWithUserInfo := fmt.Sprintf("http://alice:hunter2@%s/oauth/start?client_secret=leak#frag", parsed.Host)
	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          startWithUserInfo,
		ResponseMode: "envelope",
	})
	require.Positive(t, code)

	var resp httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &resp))
	require.NotNil(t, resp.Trace)
	assert.Equal(t, srv.URL+"/oauth/callback", resp.Trace.FinalURL)
	assert.Equal(t, 1, resp.Trace.RedirectCount)
	require.Len(t, resp.Trace.Hops, 2)
	assert.Equal(t, srv.URL+"/oauth/start", resp.Trace.Hops[0].URL)
	assert.Equal(t, srv.URL+"/oauth/callback", resp.Trace.Hops[1].URL)

	rawStr := string(raw)
	for _, secret := range []string{"hunter2", "alice", "client_secret", "top-secret-code", "access_token", "?", "#"} {
		assert.NotContains(t, rawStr, secret)
	}

	// Exceeding 10 redirects fails closed.
	code, _ = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/loop?n=0",
		ResponseMode: "envelope",
	})
	assert.Equal(t, pluginErrInternal, code)
}

func TestPluginHTTPTraceDNSAndHappyEyeballsRace(t *testing.T) {
	t.Parallel()

	initialURL, err := url.Parse("https://app.example.com/health?token=secret#frag")
	require.NoError(t, err)

	trace := newPluginHTTPTrace(initialURL)
	trace.markStart()
	ct := trace.clientTrace()

	ct.DNSStart(httptrace.DNSStartInfo{Host: "app.example.com"})
	time.Sleep(2 * time.Millisecond)
	ct.DNSDone(httptrace.DNSDoneInfo{})

	// Simulate concurrent Happy Eyeballs ConnectStart/ConnectDone under -race.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		ct.ConnectStart("tcp", "[::1]:443")
		time.Sleep(time.Millisecond)
		ct.ConnectDone("tcp", "[::1]:443", assert.AnError)
	}()
	go func() {
		defer wg.Done()
		ct.ConnectStart("tcp", "192.0.2.10:443")
		time.Sleep(2 * time.Millisecond)
		ct.ConnectDone("tcp", "192.0.2.10:443", nil)
	}()
	wg.Wait()

	ct.TLSHandshakeStart()
	time.Sleep(time.Millisecond)
	ct.TLSHandshakeDone(tls.ConnectionState{}, nil)
	ct.GotConn(httptrace.GotConnInfo{Reused: false})
	ct.WroteRequest(httptrace.WroteRequestInfo{})
	time.Sleep(time.Millisecond)
	ct.GotFirstResponseByte()

	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, initialURL.String(), nil)
	require.NoError(t, err)
	resp := &http.Response{
		StatusCode: http.StatusOK,
		Proto:      "HTTP/2.0",
		Request:    req,
	}

	built := trace.finishAndBuild(resp, time.Now())
	require.NotNil(t, built)
	assert.Positive(t, built.DNSDurationNS)
	assert.Positive(t, built.ConnectDurationNS)
	assert.Positive(t, built.TLSHandshakeDurationNS)
	assert.Positive(t, built.TTFBDurationNS)
	assert.Positive(t, built.TotalDurationNS)
	assert.Equal(t, "https://app.example.com/health", built.FinalURL)
	assert.Equal(t, "HTTP/2.0", built.Protocol)
	require.Len(t, built.Hops, 1)
	assert.Equal(t, "https://app.example.com/health", built.Hops[0].URL)
	assert.Positive(t, built.Hops[0].DNSDurationNS)
}

func TestPluginHostHTTPResponseModeCompatibility(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Set-Cookie", "a=1; Path=/")
		_, _ = w.Write([]byte("hello"))
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	exec, mod := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}, nil, nil)

	// status_body returns "<status>\n<body>".
	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL,
		ResponseMode: "status_body",
	})
	require.Positive(t, code)
	assert.Equal(t, "200\nhello", string(raw))

	// Legacy empty response_mode omits trace, tls, and set_cookies.
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method: http.MethodGet,
		URL:    srv.URL,
	})
	require.Positive(t, code)

	var decoded map[string]any
	require.NoError(t, json.Unmarshal(raw, &decoded))
	assert.InDelta(t, 200, decoded["status"], 0)
	assert.Equal(t, base64.StdEncoding.EncodeToString([]byte("hello")), decoded["body_base64"])
	_, hasTrace := decoded["trace"]
	_, hasTLS := decoded["tls"]
	_, hasSetCookies := decoded["set_cookies"]
	assert.False(t, hasTrace)
	assert.False(t, hasTLS)
	assert.False(t, hasSetCookies)
}

func TestPluginHTTPRedirectSameHostCanonicalizesDefaultPorts(t *testing.T) {
	t.Parallel()

	cases := []struct {
		origin, next string
		same         bool
	}{
		{"https://app.example/login", "https://app.example:443/session", true},
		{"http://app.example/login", "http://app.example:80/session", true},
		{"https://app.example./login", "https://app.example/session", true},
		{"https://APP.example/login", "https://app.example/session", true},
		{"https://app.example/login", "http://app.example/login", true},
		{"http://127.0.0.1:8080/login", "http://127.0.0.1:8081/login", false},
		{"https://app.example/login", "https://app.example:8443/login", false},
		{"https://app.example/login", "https://collector.example/sink", false},
	}
	for _, tc := range cases {
		origin, err := url.Parse(tc.origin)
		require.NoError(t, err)
		next, err := url.Parse(tc.next)
		require.NoError(t, err)
		assert.Equal(t, tc.same, pluginHTTPRedirectSameHost(next, origin), "%s -> %s", tc.origin, tc.next)
	}
}

func newSizedPluginHTTPHostTestExecution(
	t *testing.T,
	permissions pluginPermissions,
	memoryPages uint32,
) (*pluginExecution, api.Module) {
	t.Helper()

	permissions.normalize()
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger: logger.NewTestLogger(),
	})
	t.Cleanup(manager.Stop)

	assignment := &pluginAssignment{
		AssignmentID: "http-large-test",
		PluginID:     "http-large-test",
		Capabilities: map[string]bool{"http_request": true},
		Permissions:  permissions,
		Timeout:      5 * time.Second,
	}

	rt := wazero.NewRuntime(t.Context())
	t.Cleanup(func() {
		_ = rt.Close(t.Context())
	})

	// Encode unsigned LEB128 initial memory page count for a single Wasm memory export.
	var pageLEB []byte
	v := memoryPages
	for {
		b := byte(v & 0x7f)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		pageLEB = append(pageLEB, b)
		if v == 0 {
			break
		}
	}

	wasm := make([]byte, 0, 12+len(pageLEB)+12)
	wasm = append(wasm,
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		0x05, byte(2+len(pageLEB)), 0x01, 0x00,
	)
	wasm = append(wasm, pageLEB...)
	wasm = append(wasm, 0x07, 0x0a, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00)

	mod, err := rt.Instantiate(t.Context(), wasm)
	require.NoError(t, err)

	return newPluginExecution(manager, assignment), mod
}

func TestPluginHostHTTPAllowsLargeBodyAndTransparentGzip(t *testing.T) {
	t.Parallel()

	require.Equal(t, 16*1024*1024, pluginMaxHTTPBodyBytes)

	largeBody := bytes.Repeat([]byte("a"), 3*1024*1024)
	var gzBuf bytes.Buffer
	gzw := gzip.NewWriter(&gzBuf)
	_, err := gzw.Write(largeBody)
	require.NoError(t, err)
	require.NoError(t, gzw.Close())
	gzBytes := gzBuf.Bytes()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/raw":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(largeBody)
		case "/gzip":
			assert.Contains(t, r.Header.Get("Accept-Encoding"), "gzip")
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Encoding", "gzip")
			_, _ = w.Write(gzBytes)
		}
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	// 160 pages = 10 MiB Wasm linear memory so 3 MiB raw + 4 MiB base64 envelope fits easily.
	exec, mod := newSizedPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}, 160)

	const (
		reqPtr  = uint32(0)
		respPtr = uint32(64 * 1024)
		respLen = uint32(6 * 1024 * 1024)
	)

	// 1. Raw >2 MiB body in status_body mode.
	reqBytes, err := json.Marshal(httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/raw",
		ResponseMode: "status_body",
	})
	require.NoError(t, err)
	require.True(t, mod.Memory().Write(reqPtr, reqBytes))

	n := exec.hostHTTPRequest(t.Context(), mod, reqPtr, uint32(len(reqBytes)), respPtr, respLen)
	require.Positive(t, n)
	gotRaw, ok := mod.Memory().Read(respPtr, uint32(n))
	require.True(t, ok)
	require.Equal(t, "200\n", string(gotRaw[:4]))
	require.Equal(t, largeBody, gotRaw[4:])

	// 2. Transparent gzip decompression >2 MiB in envelope mode (caller omits Accept-Encoding).
	reqBytes, err = json.Marshal(httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/gzip",
		ResponseMode: "envelope",
	})
	require.NoError(t, err)
	require.True(t, mod.Memory().Write(reqPtr, reqBytes))

	n = exec.hostHTTPRequest(t.Context(), mod, reqPtr, uint32(len(reqBytes)), respPtr, respLen)
	require.Positive(t, n)
	gotEnv, ok := mod.Memory().Read(respPtr, uint32(n))
	require.True(t, ok)

	var respEnv httpResponsePayload
	require.NoError(t, json.Unmarshal(gotEnv, &respEnv))
	assert.Equal(t, http.StatusOK, respEnv.Status)
	decodedBody, err := base64.StdEncoding.DecodeString(respEnv.BodyBase64)
	require.NoError(t, err)
	assert.Equal(t, largeBody, decodedBody)
}

func TestPluginHostHTTPConditionalETag(t *testing.T) {
	t.Parallel()

	var (
		mu              sync.Mutex
		seenIfNoneMatch []string
		currentETag     = `"snap-v1"`
		currentBody     = `{"version":1}`
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		inm := r.Header.Get("If-None-Match")
		seenIfNoneMatch = append(seenIfNoneMatch, inm)
		etag := currentETag
		body := currentBody
		mu.Unlock()

		if etag != "" && inm == etag {
			w.Header().Set("ETag", etag)
			w.WriteHeader(http.StatusNotModified)
			return
		}
		if etag != "" {
			w.Header().Set("ETag", etag)
		}
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	port := serverPortFromURL(t, srv.URL)
	exec, mod := newPluginHTTPHostTestExecution(t, pluginPermissions{
		AllowedNetworks: []string{"127.0.0.0/8"},
		AllowedPorts:    []int{port},
	}, nil, nil)

	// Disabled by default: subsequent GET does not send If-None-Match.
	code, raw := callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/snapshot?compact=1",
		ResponseMode: "envelope",
	})
	require.Positive(t, code)
	var firstDefault httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &firstDefault))
	assert.Equal(t, http.StatusOK, firstDefault.Status)

	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:       http.MethodGet,
		URL:          srv.URL + "/snapshot?compact=1",
		ResponseMode: "envelope",
	})
	require.Positive(t, code)
	var secondDefault httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &secondDefault))
	assert.Equal(t, http.StatusOK, secondDefault.Status)

	// Opt-in conditional_etag: 1st GET caches ETag, 2nd GET injects If-None-Match and gets 304.
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + "/snapshot?compact=1",
		ResponseMode:    "envelope",
		ConditionalETag: true,
	})
	require.Positive(t, code)
	var optFirst httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &optFirst))
	assert.Equal(t, http.StatusOK, optFirst.Status)

	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + "/snapshot?compact=1",
		ResponseMode:    "envelope",
		ConditionalETag: true,
	})
	require.Positive(t, code)
	var optNotModified httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &optNotModified))
	assert.Equal(t, http.StatusNotModified, optNotModified.Status)
	assert.Empty(t, optNotModified.BodyBase64)

	// Server rotates ETag -> next GET sends old ETag, gets 200 and updates cache to snap-v2.
	mu.Lock()
	currentETag = `"snap-v2"`
	currentBody = `{"version":2}`
	mu.Unlock()

	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + "/snapshot?compact=1",
		ResponseMode:    "envelope",
		ConditionalETag: true,
	})
	require.Positive(t, code)
	var rotated httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &rotated))
	assert.Equal(t, http.StatusOK, rotated.Status)

	// Explicit caller If-None-Match is preserved rather than overwritten.
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + "/snapshot?compact=1",
		Headers:         map[string]string{"If-None-Match": `"caller-etag"`},
		ResponseMode:    "envelope",
		ConditionalETag: true,
	})
	require.Positive(t, code)
	var callerInm httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &callerInm))
	assert.Equal(t, http.StatusOK, callerInm.Status)

	// Removing assignment via refreshAssignmentStates clears cached ETag.
	exec.manager.refreshAssignmentStates(nil)
	code, raw = callPluginHostHTTPPayload(t, exec, mod, httpRequestPayload{
		Method:          http.MethodGet,
		URL:             srv.URL + "/snapshot?compact=1",
		ResponseMode:    "envelope",
		ConditionalETag: true,
	})
	require.Positive(t, code)
	var afterRemoval httpResponsePayload
	require.NoError(t, json.Unmarshal(raw, &afterRemoval))
	assert.Equal(t, http.StatusOK, afterRemoval.Status)

	mu.Lock()
	gotHeaders := append([]string(nil), seenIfNoneMatch...)
	mu.Unlock()
	assert.Equal(t, []string{
		"",
		"",
		"",
		`"snap-v1"`,
		`"snap-v1"`,
		`"caller-etag"`,
		"",
	}, gotHeaders)

	// Cache size remains bounded at pluginHTTPETagMaxEntries.
	var bounded pluginHTTPETagCache
	for i := range pluginHTTPETagMaxEntries + 16 {
		bounded.put("assign-1", fmt.Sprintf("https://example.test/snap/%d", i), fmt.Sprintf(`"e-%d"`, i))
	}
	assert.Len(t, bounded.entries, pluginHTTPETagMaxEntries)
	// Control-character ETag is refused and never stored.
	bounded.put("assign-1", "https://example.test/bad", "\"bad\r\n\"")
	_, ok := bounded.get("assign-1", "https://example.test/bad")
	assert.False(t, ok)
	// Oversized ETag is refused.
	bounded.put("assign-1", "https://example.test/big", strings.Repeat("x", pluginHTTPETagMaxValueBytes+1))
	_, ok = bounded.get("assign-1", "https://example.test/big")
	assert.False(t, ok)
}
