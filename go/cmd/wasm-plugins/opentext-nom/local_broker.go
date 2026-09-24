//go:build !tinygo

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	localTokenResponseLimit = 64 * 1024
	localTokenLimit         = 8 * 1024
	// Same reuse policy as the agent's credential broker: honor expires_in,
	// but never beyond NA's documented 20-minute token, and refresh early.
	localTokenMaxTTL       = 15 * time.Minute
	localTokenExpiryMargin = 60 * time.Second
)

type localOAuthBroker struct {
	config     Config
	username   string
	password   string
	httpClient *http.Client
	errorMu    sync.Mutex
	safeError  string
	tokenMu    sync.Mutex
	token      []byte
	tokenUntil time.Time
	now        func() time.Time
}

type localOAuthTokenResponse struct {
	AccessToken string          `json:"access_token"`
	ExpiresIn   json.RawMessage `json:"expires_in"`
}

// lifetimeSeconds reads expires_in as a JSON number or numeric string. Anything
// else is 0, which cacheToken treats as "do not cache" rather than a failed
// login.
func (r localOAuthTokenResponse) lifetimeSeconds() int64 {
	raw := strings.Trim(strings.TrimSpace(string(r.ExpiresIn)), `"`)
	seconds, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || seconds < 0 {
		return 0
	}
	return seconds
}

func newLocalOAuthBroker(
	config Config,
	credentials map[string]string,
	httpClient *http.Client,
) (*localOAuthBroker, error) {
	if err := config.Validate(); err != nil {
		return nil, errors.New("local host received an invalid plugin configuration")
	}
	username := credentials["username"]
	password := credentials["password"]
	if strings.TrimSpace(username) == "" || password == "" {
		return nil, errors.New("local host requires SERVICERADAR_CREDENTIAL_USERNAME and SERVICERADAR_CREDENTIAL_PASSWORD")
	}

	client := &http.Client{Timeout: time.Duration(config.RequestTimeoutSeconds) * time.Second}
	if httpClient != nil {
		clone := *httpClient
		client = &clone
		if client.Timeout == 0 {
			client.Timeout = time.Duration(config.RequestTimeoutSeconds) * time.Second
		}
	} else {
		applyLocalTLS(client)
	}
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}

	return &localOAuthBroker{
		config:     config,
		username:   username,
		password:   password,
		httpClient: client,
	}, nil
}

func (b *localOAuthBroker) Handle(
	ctx context.Context,
	request sdk.HTTPRequest,
) (*sdk.HTTPResponse, error) {
	if b == nil || b.httpClient == nil {
		return nil, runError("opentext_nom_local_host_unavailable")
	}
	b.setSafeError("")
	if (request.InsecureSkipVerify && !localTLSInsecure()) ||
		!strings.EqualFold(request.Method, http.MethodPost) ||
		request.URL != b.config.APIURL || hasAuthorizationHeader(request.Headers) {
		return nil, b.fail("opentext_nom_local_target_denied")
	}

	token, err := b.bearerToken(ctx)
	if err != nil {
		return nil, err
	}
	defer clear(token)

	upstreamRequest, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		b.config.APIURL,
		bytes.NewReader(request.Body),
	)
	if err != nil {
		return nil, b.fail("opentext_nom_local_request_invalid")
	}
	for key, value := range request.Headers {
		if strings.TrimSpace(key) != "" {
			upstreamRequest.Header.Set(key, value)
		}
	}
	upstreamRequest.Header.Set("Authorization", "Bearer "+string(token))
	if upstreamRequest.Header.Get("User-Agent") == "" {
		upstreamRequest.Header.Set("User-Agent", "curl/7.68.0")
	}

	response, err := b.httpClient.Do(upstreamRequest)
	if err != nil {
		return nil, b.fail("opentext_nom_local_upstream_unavailable")
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode == http.StatusUnauthorized {
		b.dropCachedToken(token)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, int64(sdk.MaxHTTPResponseBytes)+1))
	if err != nil {
		return nil, b.fail("opentext_nom_local_upstream_unavailable")
	}
	if len(body) > sdk.MaxHTTPResponseBytes {
		clear(body)
		return nil, b.fail("opentext_nom_local_response_too_large")
	}
	return &sdk.HTTPResponse{
		Status:  response.StatusCode,
		Headers: localResponseHeaders(response.Header),
		Body:    body,
	}, nil
}

func (b *localOAuthBroker) exchangeToken(ctx context.Context) ([]byte, error) {
	form := url.Values{
		"username":   []string{b.username},
		"password":   []string{b.password},
		"grant_type": []string{"password"},
	}
	if b.config.UsesDirectNAToken() {
		form.Set("client_id", directNAClientID)
		form.Set("client_secret", directNAClientSecret)
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		b.config.TokenURL,
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("User-Agent", "curl/7.68.0")

	response, err := b.httpClient.Do(request)
	if err != nil {
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, localTokenResponseLimit+1))
	if err != nil || len(body) > localTokenResponseLimit {
		clear(body)
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	defer clear(body)

	decoder := json.NewDecoder(bytes.NewReader(body))
	var tokenResponse localOAuthTokenResponse
	if err := decoder.Decode(&tokenResponse); err != nil {
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	token := []byte(strings.TrimSpace(tokenResponse.AccessToken))
	if len(token) == 0 || len(token) > localTokenLimit ||
		bytes.Contains(token, []byte{'\r'}) || bytes.Contains(token, []byte{'\n'}) {
		clear(token)
		return nil, b.fail("opentext_nom_local_token_exchange_failed")
	}
	b.cacheToken(token, tokenResponse.lifetimeSeconds())
	return token, nil
}

// bearerToken returns a copy of the cached token while it is still valid, and
// otherwise exchanges a new one. The caller clears its copy after use.
func (b *localOAuthBroker) bearerToken(ctx context.Context) ([]byte, error) {
	b.tokenMu.Lock()
	if len(b.token) > 0 && b.clock().Before(b.tokenUntil) {
		token := append([]byte(nil), b.token...)
		b.tokenMu.Unlock()
		return token, nil
	}
	b.tokenMu.Unlock()
	return b.exchangeToken(ctx)
}

func (b *localOAuthBroker) cacheToken(token []byte, expiresIn int64) {
	if expiresIn <= 0 {
		return
	}
	ttl := time.Duration(expiresIn) * time.Second
	if ttl > localTokenMaxTTL {
		ttl = localTokenMaxTTL
	}
	ttl -= localTokenExpiryMargin
	if ttl <= 0 {
		return
	}
	b.tokenMu.Lock()
	defer b.tokenMu.Unlock()
	clear(b.token)
	b.token = append([]byte(nil), token...)
	b.tokenUntil = b.clock().Add(ttl)
}

// dropCachedToken evicts the cache only if it still holds the token the
// upstream rejected, so a late 401 cannot discard a token a concurrent request
// has already refreshed.
func (b *localOAuthBroker) dropCachedToken(rejected []byte) {
	b.tokenMu.Lock()
	defer b.tokenMu.Unlock()
	if !bytes.Equal(b.token, rejected) {
		return
	}
	clear(b.token)
	b.token = nil
	b.tokenUntil = time.Time{}
}

func (b *localOAuthBroker) clock() time.Time {
	if b.now != nil {
		return b.now()
	}
	return time.Now()
}

func (b *localOAuthBroker) SafeError() string {
	if b == nil {
		return "opentext_nom_local_host_unavailable"
	}
	b.errorMu.Lock()
	defer b.errorMu.Unlock()
	return b.safeError
}

func (b *localOAuthBroker) fail(code string) error {
	b.setSafeError(code)
	return runError(code)
}

func (b *localOAuthBroker) setSafeError(code string) {
	b.errorMu.Lock()
	b.safeError = code
	b.errorMu.Unlock()
}

func hasAuthorizationHeader(headers map[string]string) bool {
	for key := range headers {
		if strings.EqualFold(strings.TrimSpace(key), "Authorization") {
			return true
		}
	}
	return false
}

func localTLSInsecure() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("SERVICERADAR_LOCAL_TLS_INSECURE"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func applyLocalTLS(client *http.Client) {
	if client == nil || !localTLSInsecure() {
		return
	}
	var transport *http.Transport
	switch existing := client.Transport.(type) {
	case *http.Transport:
		transport = existing.Clone()
	default:
		if base, ok := http.DefaultTransport.(*http.Transport); ok {
			transport = base.Clone()
		} else {
			transport = &http.Transport{}
		}
	}
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true} //nolint:gosec // local host only
	if transport.TLSClientConfig != nil {
		tlsCfg = transport.TLSClientConfig.Clone()
		tlsCfg.InsecureSkipVerify = true
	}
	transport.TLSClientConfig = tlsCfg
	client.Transport = transport
}

func localResponseHeaders(headers http.Header) map[string]string {
	result := make(map[string]string, len(headers))
	for key, values := range headers {
		result[key] = strings.Join(values, ", ")
	}
	return result
}
