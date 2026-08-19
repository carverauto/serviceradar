//go:build !tinygo

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

const (
	localTokenResponseLimit = 64 * 1024
	localTokenLimit         = 8 * 1024
)

type localOAuthBroker struct {
	config     Config
	username   string
	password   string
	httpClient *http.Client
	errorMu    sync.Mutex
	safeError  string
}

type localOAuthTokenResponse struct {
	AccessToken string `json:"access_token"`
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
		return nil, runError("network_automation_local_host_unavailable")
	}
	b.setSafeError("")
	if request.InsecureSkipVerify || !strings.EqualFold(request.Method, http.MethodPost) ||
		request.URL != b.config.APIURL || hasAuthorizationHeader(request.Headers) {
		return nil, b.fail("network_automation_local_target_denied")
	}

	token, err := b.exchangeToken(ctx)
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
		return nil, b.fail("network_automation_local_request_invalid")
	}
	for key, value := range request.Headers {
		if strings.TrimSpace(key) != "" {
			upstreamRequest.Header.Set(key, value)
		}
	}
	upstreamRequest.Header.Set("Authorization", "Bearer "+string(token))

	response, err := b.httpClient.Do(upstreamRequest)
	if err != nil {
		return nil, b.fail("network_automation_local_upstream_unavailable")
	}
	defer func() { _ = response.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(response.Body, int64(sdk.MaxHTTPResponseBytes)+1))
	if err != nil {
		return nil, b.fail("network_automation_local_upstream_unavailable")
	}
	if len(body) > sdk.MaxHTTPResponseBytes {
		clear(body)
		return nil, b.fail("network_automation_local_response_too_large")
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
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		b.config.TokenURL,
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	response, err := b.httpClient.Do(request)
	if err != nil {
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, localTokenResponseLimit+1))
	if err != nil || len(body) > localTokenResponseLimit {
		clear(body)
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	defer clear(body)

	decoder := json.NewDecoder(bytes.NewReader(body))
	var tokenResponse localOAuthTokenResponse
	if err := decoder.Decode(&tokenResponse); err != nil {
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	token := []byte(strings.TrimSpace(tokenResponse.AccessToken))
	if len(token) == 0 || len(token) > localTokenLimit ||
		bytes.Contains(token, []byte{'\r'}) || bytes.Contains(token, []byte{'\n'}) {
		clear(token)
		return nil, b.fail("network_automation_local_token_exchange_failed")
	}
	return token, nil
}

func (b *localOAuthBroker) SafeError() string {
	if b == nil {
		return "network_automation_local_host_unavailable"
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

func localResponseHeaders(headers http.Header) map[string]string {
	result := make(map[string]string, len(headers))
	for key, values := range headers {
		result[key] = strings.Join(values, ", ")
	}
	return result
}
