/*
 * Copyright 2026 Carver Automation Corporation.
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

package armis

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	accessTokenPath = "/api/v1/access_token/"
	searchPath      = "/api/v1/search/"
)

var (
	errTokenRequestFailed      = errors.New("armis token request failed")
	errTokenMissingAccessToken = errors.New("armis token response missing access_token")
	errSearchFailed            = errors.New("armis search failed")
)

type client struct {
	endpoint           string
	insecureSkipVerify bool
}

type requestError struct {
	err        error
	statusCode int
	status     string
	body       string
}

func (e *requestError) Error() string {
	if e.body != "" {
		return fmt.Sprintf("%v: %s: %s", e.err, e.status, e.body)
	}

	return fmt.Sprintf("%v: %s", e.err, e.status)
}

func (e *requestError) Unwrap() error {
	return e.err
}

func isUnauthorized(err error) bool {
	var reqErr *requestError
	return errors.As(err, &reqErr) && reqErr.statusCode == http.StatusUnauthorized
}

func newClient(source models.SourceConfig) *client {
	return &client{
		endpoint:           strings.TrimRight(source.Endpoint, "/"),
		insecureSkipVerify: source.InsecureSkipVerify,
	}
}

func (c *client) accessToken(ctx context.Context, creds map[string]string) (string, error) {
	endpoint, err := c.resolveURL(accessTokenPath)
	if err != nil {
		return "", err
	}

	form := url.Values{}
	if key := secretKey(creds); key != "" {
		form.Set("secret_key", key)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if len(body) > 0 {
			return "", fmt.Errorf("%w: %s: %s", errTokenRequestFailed, resp.Status, strings.TrimSpace(string(body)))
		}

		return "", fmt.Errorf("%w: %s", errTokenRequestFailed, resp.Status)
	}

	var token tokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&token); err != nil {
		return "", err
	}
	if token.Data.AccessToken == "" {
		return "", errTokenMissingAccessToken
	}

	return token.Data.AccessToken, nil
}

func secretKey(creds map[string]string) string {
	return firstCredentialValue(creds, "secret_key", "api_secret", "api_key", "key")
}

func firstCredentialValue(creds map[string]string, keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(creds[key]); value != "" {
			return value
		}
	}

	return ""
}

func (c *client) search(ctx context.Context, token string, query string, from int, length int) (*searchResponse, error) {
	endpoint, err := c.resolveURL(searchPath)
	if err != nil {
		return nil, err
	}

	parsed, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}

	params := parsed.Query()
	params.Set("length", strconv.Itoa(length))
	if from > 0 {
		params.Set("from", strconv.Itoa(from))
	}
	if query != "" {
		params.Set("aql", query)
	}
	parsed.RawQuery = params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, &requestError{
			err:        errSearchFailed,
			statusCode: resp.StatusCode,
			status:     resp.Status,
			body:       strings.TrimSpace(string(body)),
		}
	}

	var result searchResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return &result, nil
}

func (c *client) resolveURL(path string) (string, error) {
	base, err := url.Parse(c.endpoint)
	if err != nil {
		return "", err
	}

	ref, err := url.Parse(path)
	if err != nil {
		return "", err
	}

	return base.ResolveReference(ref).String(), nil
}

func (c *client) httpClient() *http.Client {
	transport := http.DefaultTransport
	if c.insecureSkipVerify {
		transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}

	return &http.Client{Transport: transport}
}
