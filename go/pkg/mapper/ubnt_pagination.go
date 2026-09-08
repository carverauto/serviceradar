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

package mapper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

const (
	uniFiAPIPageLimit = 500
	uniFiAPIMaxPages  = 200
)

var (
	errUniFiUnexpectedStatus        = errors.New("unexpected response status")
	errUniFiOffsetPagingUnsupported = errors.New("controller may not support offset paging")
)

func fetchUniFiPagedData[T any](
	ctx context.Context,
	client *http.Client,
	headers map[string]string,
	baseURL string,
	resourceName string,
	controllerName string,
	siteName string,
) ([]T, error) {
	return fetchUniFiPagedDataWithPageCap[T](
		ctx,
		client,
		headers,
		baseURL,
		resourceName,
		controllerName,
		siteName,
		uniFiAPIMaxPages,
	)
}

func fetchUniFiPagedDataWithPageCap[T any](
	ctx context.Context,
	client *http.Client,
	headers map[string]string,
	baseURL string,
	resourceName string,
	controllerName string,
	siteName string,
	maxPages int,
) ([]T, error) {
	allData := make([]T, 0)
	previousFirstRecord := ""

	for page := 0; page < maxPages; page++ {
		offset := page * uniFiAPIPageLimit
		pageURL := fmt.Sprintf("%s?limit=%d&offset=%d", baseURL, uniFiAPIPageLimit, offset)

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, pageURL, http.NoBody)
		if err != nil {
			return nil, fmt.Errorf("failed to create %s request for %s, site %s, offset %d: %w",
				resourceName, controllerName, siteName, offset, err)
		}

		for k, v := range headers {
			req.Header.Set(k, v)
		}

		resp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("failed to fetch %s from %s, site %s, offset %d: %w",
				resourceName, controllerName, siteName, offset, err)
		}

		body, readErr := io.ReadAll(resp.Body)
		closeErr := resp.Body.Close()
		if readErr != nil {
			return nil, fmt.Errorf("failed to read %s response body from %s, site %s, offset %d: %w",
				resourceName, controllerName, siteName, offset, readErr)
		}
		if closeErr != nil {
			return nil, fmt.Errorf("failed to close %s response body from %s, site %s, offset %d: %w",
				resourceName, controllerName, siteName, offset, closeErr)
		}

		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s request failed for %s, site %s, offset %d with status %d, body %s: %w",
				resourceName, controllerName, siteName, offset, resp.StatusCode, string(body), errUniFiUnexpectedStatus)
		}

		var pageResp struct {
			Data []T `json:"data"`
		}
		if err := json.Unmarshal(body, &pageResp); err != nil {
			return nil, fmt.Errorf("failed to parse %s response from %s, site %s, offset %d: %w",
				resourceName, controllerName, siteName, offset, err)
		}

		firstRecord, hasFirstRecord, err := uniFiFirstRecordFingerprint(pageResp.Data)
		if err != nil {
			return nil, fmt.Errorf("failed to fingerprint %s response from %s, site %s, offset %d: %w",
				resourceName, controllerName, siteName, offset, err)
		}
		if hasFirstRecord {
			if previousFirstRecord != "" && firstRecord == previousFirstRecord {
				return nil, fmt.Errorf("%s pagination repeated the first record for %s, site %s, offset %d; %w",
					resourceName, controllerName, siteName, offset, errUniFiOffsetPagingUnsupported)
			}
			previousFirstRecord = firstRecord
		}

		allData = append(allData, pageResp.Data...)
		if len(pageResp.Data) < uniFiAPIPageLimit {
			return allData, nil
		}
	}

	return nil, fmt.Errorf("%s pagination exceeded %d pages (%d records) for %s, site %s; %w",
		resourceName, maxPages, maxPages*uniFiAPIPageLimit, controllerName, siteName, errUniFiOffsetPagingUnsupported)
}

func uniFiFirstRecordFingerprint[T any](data []T) (string, bool, error) {
	if len(data) == 0 {
		return "", false, nil
	}

	payload, err := json.Marshal(data[0])
	if err != nil {
		return "", false, err
	}

	return string(payload), true, nil
}
