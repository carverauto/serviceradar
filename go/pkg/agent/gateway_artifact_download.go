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

package agent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const maxBumblebeeCatalogBytes = 32 * 1024 * 1024

var (
	errGatewayArtifactObjectMismatch  = errors.New("gateway artifact object key mismatch")
	errBumblebeeCatalogDownloadFailed = errors.New("bumblebee catalog gateway download failed")
	errBumblebeeCatalogTooLarge       = errors.New("bumblebee catalog exceeds size budget")
)

// gatewayArtifactStatusError is returned when a gateway artifact download responds
// with a non-200 status. It wraps the caller-supplied sentinel (e.g.
// ErrAddonArtifactDownloadFailed) AND carries the HTTP status code so callers can
// classify the failure as permanent (4xx, e.g. a 404 for a not-yet-uploaded object)
// versus transient (5xx / gateway hiccup) without parsing the error string.
type gatewayArtifactStatusError struct {
	sentinel   error
	statusCode int
}

func (e *gatewayArtifactStatusError) Error() string {
	return fmt.Sprintf("%v: status %d", e.sentinel, e.statusCode)
}

// Unwrap exposes the caller's sentinel so errors.Is(err, ErrAddonArtifactDownloadFailed)
// continues to match.
func (e *gatewayArtifactStatusError) Unwrap() error {
	return e.sentinel
}

// StatusCode reports the HTTP status code that produced the failure.
func (e *gatewayArtifactStatusError) StatusCode() int {
	return e.statusCode
}

type gatewayArtifactDownloader struct {
	client      *http.Client
	downloadURL string
	token       string
	objectKey   string
	maxBytes    int64
	statusErr   error
	tooLargeErr error
}

type gatewayArtifactUnavailableTransport struct {
	err error
}

func (t gatewayArtifactUnavailableTransport) RoundTrip(*http.Request) (*http.Response, error) {
	if t.err != nil {
		return nil, t.err
	}
	return nil, errReleaseGatewaySecurityRequired
}

func (d gatewayArtifactDownloader) DownloadObject(ctx context.Context, key string) ([]byte, error) {
	if strings.TrimSpace(key) != strings.TrimSpace(d.objectKey) {
		return nil, errGatewayArtifactObjectMismatch
	}
	return downloadGatewayArtifactHTTP(ctx, d.client, d.downloadURL, d.token, d.maxBytes, d.statusErr, d.tooLargeErr)
}

func downloadGatewayArtifactHTTP(
	ctx context.Context,
	client *http.Client,
	downloadURL string,
	token string,
	maxBytes int64,
	statusErr error,
	tooLargeErr error,
) ([]byte, error) {
	if client == nil {
		return nil, errDownloadFailed
	}
	if maxBytes <= 0 {
		maxBytes = maxAddonTarballBytes
	}
	if statusErr == nil {
		statusErr = errDownloadFailed
	}
	if tooLargeErr == nil {
		tooLargeErr = errDownloadTooLarge
	}

	method := http.MethodGet
	if strings.TrimSpace(token) != "" {
		method = http.MethodPost
	}

	req, err := http.NewRequestWithContext(ctx, method, downloadURL, nil)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(token) != "" {
		req.Header.Set("X-ServiceRadar-Plugin-Token", token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, &gatewayArtifactStatusError{sentinel: statusErr, statusCode: resp.StatusCode}
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("%w: exceeds %d bytes", tooLargeErr, maxBytes)
	}

	return data, nil
}

func defaultGatewayArtifactHTTPClient() *http.Client {
	return &http.Client{
		Timeout:       5 * time.Minute,
		CheckRedirect: validateReleaseRedirect,
	}
}

func unavailableGatewayArtifactHTTPClient(err error) *http.Client {
	return &http.Client{
		Timeout:       5 * time.Minute,
		Transport:     gatewayArtifactUnavailableTransport{err: err},
		CheckRedirect: validateReleaseRedirect,
	}
}
