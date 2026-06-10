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
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// emitRecorder captures the update batches a driver emits, standing in for
// the runtime's gateway streaming pipeline.
type emitRecorder struct {
	mu    sync.Mutex
	pages [][]map[string]any
}

func (e *emitRecorder) emit(updates []map[string]any) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	copied := append([]map[string]any(nil), updates...)
	e.pages = append(e.pages, copied)
	return nil
}

func (e *emitRecorder) deviceIDs() []string {
	e.mu.Lock()
	defer e.mu.Unlock()

	var deviceIDs []string
	for _, page := range e.pages {
		for _, update := range page {
			deviceID, _ := update["device_id"].(string)
			deviceIDs = append(deviceIDs, deviceID)
		}
	}
	return deviceIDs
}

func (e *emitRecorder) pageCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.pages)
}

func testRunContext(source models.SourceConfig, emit syncsources.EmitFunc) syncsources.RunContext {
	return syncsources.RunContext{
		RunID:     "run-123",
		SourceKey: "armis",
		AgentID:   "agent-a",
		GatewayID: "gateway-a",
		Partition: "partition-a",
		Source:    source,
		Logger:    logger.NewTestLogger(),
		Emit:      emit,
	}
}

func TestSyncRequiresConfiguredQueries(t *testing.T) {
	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type:     SourceType,
		Endpoint: "https://armis.example",
	}, recorder.emit)

	_, err := NewDriver().Sync(context.Background(), run)
	if !errors.Is(err, errNoQueriesConfigured) {
		t.Fatalf("error = %v, want errNoQueriesConfigured", err)
	}
}

func TestSyncEmitsFetchedPagesBeforeLaterSearchError(t *testing.T) {
	var searchCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case searchPath:
			searchCalls++
			if got := r.URL.Query().Get("from"); got == "2" {
				http.Error(w, "second page failed", http.StatusBadRequest)
				return
			}
			if _, ok := r.URL.Query()["from"]; ok {
				t.Fatalf("first page should omit from, got %q", r.URL.RawQuery)
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"data":{
					"count":2,
					"next":2,
					"prev":null,
					"results":[
						{"id":101,"ipAddress":"10.0.0.101","name":"device-101"},
						{"id":102,"ipAddress":"10.0.0.102","name":"device-102"}
					],
					"total":4
				},
				"success":true
			}`))
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type:        SourceType,
		Endpoint:    server.URL,
		Credentials: map[string]string{"secret_key": "secret", "page_size": "2"},
		Queries:     []models.QueryConfig{{Label: "test", Query: testDeviceQuery}},
	}, recorder.emit)

	count, err := NewDriver().Sync(context.Background(), run)
	if err == nil {
		t.Fatal("expected second page error")
	}
	if !strings.Contains(err.Error(), "second page failed") {
		t.Fatalf("error = %q", err)
	}
	if !strings.Contains(err.Error(), "partial armis sync after streaming 2 devices") {
		t.Fatalf("error should flag partial sync, got %q", err)
	}
	if count != 2 {
		t.Fatalf("count = %d, want emitted first page count", count)
	}
	if searchCalls != 2 {
		t.Fatalf("search calls = %d, want 2", searchCalls)
	}

	gotDevices := recorder.deviceIDs()
	wantDevices := map[string]bool{"partition-a:10.0.0.101": true, "partition-a:10.0.0.102": true}
	for _, deviceID := range gotDevices {
		delete(wantDevices, deviceID)
	}
	if len(wantDevices) != 0 {
		t.Fatalf("missing emitted devices: %v; got %v", wantDevices, gotDevices)
	}
}

func TestSyncRefreshesAccessTokenOnSearchUnauthorized(t *testing.T) {
	const pageSize = 2

	var (
		mu          sync.Mutex
		tokenCalls  int
		searchCalls int
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			mu.Lock()
			tokenCalls++
			token := "token-" + strconv.Itoa(tokenCalls)
			mu.Unlock()

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"` + token + `"},"success":true}`))
		case searchPath:
			mu.Lock()
			searchCalls++
			mu.Unlock()

			auth := r.Header.Get("Authorization")
			from := r.URL.Query().Get("from")
			if from == "" {
				if auth != "token-1" {
					t.Fatalf("first page authorization = %q, want token-1", auth)
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{
					"data":{
						"count":2,
						"next":2,
						"prev":null,
						"results":[
							{"id":101,"ipAddress":"10.0.0.101","name":"device-101"},
							{"id":102,"ipAddress":"10.0.0.102","name":"device-102"}
						],
						"total":4
					},
					"success":true
				}`))
				return
			}

			if from != "2" {
				t.Fatalf("from = %q, want 2", from)
			}
			if auth == "token-1" {
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = w.Write([]byte(`{"message":"Invalid access token.","success":false}`))
				return
			}
			if auth != "token-2" {
				t.Fatalf("retry authorization = %q, want token-2", auth)
			}

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"data":{
					"count":2,
					"next":0,
					"prev":2,
					"results":[
						{"id":103,"ipAddress":"10.0.0.103","name":"device-103"},
						{"id":104,"ipAddress":"10.0.0.104","name":"device-104"}
					],
					"total":4
				},
				"success":true
			}`))
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type:        SourceType,
		Endpoint:    server.URL,
		Credentials: map[string]string{"secret_key": "secret", "page_size": strconv.Itoa(pageSize)},
		Queries:     []models.QueryConfig{{Label: "test", Query: testDeviceQuery}},
	}, recorder.emit)

	count, err := NewDriver().Sync(context.Background(), run)
	if err != nil {
		t.Fatalf("Sync returned error: %v", err)
	}
	if count != 4 {
		t.Fatalf("count = %d, want 4", count)
	}
	if tokenCalls != 2 {
		t.Fatalf("token calls = %d, want refresh after unauthorized search", tokenCalls)
	}
	if searchCalls != 3 {
		t.Fatalf("search calls = %d, want first page, failed page, retry", searchCalls)
	}

	gotDevices := recorder.deviceIDs()
	wantDevices := map[string]bool{
		"partition-a:10.0.0.101": true,
		"partition-a:10.0.0.102": true,
		"partition-a:10.0.0.103": true,
		"partition-a:10.0.0.104": true,
	}
	for _, deviceID := range gotDevices {
		delete(wantDevices, deviceID)
	}
	if len(wantDevices) != 0 {
		t.Fatalf("missing emitted devices: %v; got %v", wantDevices, gotDevices)
	}
}

func TestSyncEmitsLargePagedDatasetPerPage(t *testing.T) {
	const (
		totalDevices = 250
		pageSize     = 100
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case searchPath:
			from := 0
			if rawFrom := r.URL.Query().Get("from"); rawFrom != "" {
				parsed, err := strconv.Atoi(rawFrom)
				if err != nil {
					t.Fatalf("invalid from param %q: %v", rawFrom, err)
				}
				from = parsed
			}
			length, err := strconv.Atoi(r.URL.Query().Get("length"))
			if err != nil {
				t.Fatalf("invalid length param %q: %v", r.URL.Query().Get("length"), err)
			}
			if length != pageSize {
				t.Fatalf("length = %d, want %d", length, pageSize)
			}

			end := from + length
			if end > totalDevices {
				end = totalDevices
			}

			results := make([]map[string]interface{}, 0, end-from)
			for idx := from; idx < end; idx++ {
				deviceNumber := idx + 1
				results = append(results, map[string]interface{}{
					"id":        deviceNumber,
					"ipAddress": "10.10.0." + strconv.Itoa(deviceNumber),
					"name":      "armis-device-" + strconv.Itoa(deviceNumber),
				})
			}

			next := 0
			if end < totalDevices {
				next = end
			}

			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(map[string]interface{}{
				"data": map[string]interface{}{
					"count":   len(results),
					"next":    next,
					"prev":    nil,
					"results": results,
					"total":   totalDevices,
				},
				"success": true,
			}); err != nil {
				t.Fatalf("encode response: %v", err)
			}
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type:          SourceType,
		Endpoint:      server.URL,
		SyncServiceID: "sync-source-1",
		Credentials:   map[string]string{"secret_key": "secret", "page_size": strconv.Itoa(pageSize)},
		Queries:       []models.QueryConfig{{Label: "test", Query: testDeviceQuery}},
	}, recorder.emit)

	count, err := NewDriver().Sync(context.Background(), run)
	if err != nil {
		t.Fatalf("Sync returned error: %v", err)
	}
	if count != totalDevices {
		t.Fatalf("count = %d, want %d", count, totalDevices)
	}
	if got := recorder.pageCount(); got != 3 {
		t.Fatalf("emitted page count = %d, want 3", got)
	}

	seen := make(map[string]bool, totalDevices)
	for _, deviceID := range recorder.deviceIDs() {
		if deviceID == "" {
			t.Fatal("emitted update missing device_id")
		}
		if seen[deviceID] {
			t.Fatalf("duplicate device id %q", deviceID)
		}
		seen[deviceID] = true
	}
	if len(seen) != totalDevices {
		t.Fatalf("emitted device count = %d, want %d", len(seen), totalDevices)
	}
}

func TestSyncReleaseGateEmitsMultipleQueriesAndRefreshesToken(t *testing.T) {
	if os.Getenv("SERVICERADAR_LARGE_INGESTION_TEST") != "1" {
		t.Skip("set SERVICERADAR_LARGE_INGESTION_TEST=1 to run the 50k Armis release-gate test")
	}

	const (
		defaultTotalDevices = 50000
		pageSize            = 1000
		queryCount          = 2
	)

	totalDevices := testEnvInt("SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT", defaultTotalDevices)
	if totalDevices%queryCount != 0 {
		t.Fatalf("SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT must be divisible by %d", queryCount)
	}

	perQuery := totalDevices / queryCount
	queryStarts := map[string]int{
		"in:devices release_gate:a": 0,
		"in:devices release_gate:b": perQuery,
	}

	var (
		mu                 sync.Mutex
		tokenCalls         int
		searchCalls        int
		unauthorizedServed bool
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			mu.Lock()
			tokenCalls++
			token := "token-" + strconv.Itoa(tokenCalls)
			mu.Unlock()

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"` + token + `"},"success":true}`))
		case searchPath:
			mu.Lock()
			searchCalls++
			shouldReject := !unauthorizedServed && r.URL.Query().Get("from") != ""
			if shouldReject {
				unauthorizedServed = true
			}
			mu.Unlock()

			if shouldReject {
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = w.Write([]byte(`{"message":"Invalid access token.","success":false}`))
				return
			}

			if got := r.Header.Get("Authorization"); got == "" {
				t.Fatalf("missing authorization header")
			}

			aql := r.URL.Query().Get("aql")
			base, ok := queryStarts[aql]
			if !ok {
				t.Fatalf("unexpected aql %q", aql)
			}

			from := 0
			if rawFrom := r.URL.Query().Get("from"); rawFrom != "" {
				parsed, err := strconv.Atoi(rawFrom)
				if err != nil {
					t.Fatalf("invalid from param %q: %v", rawFrom, err)
				}
				from = parsed
			}

			length, err := strconv.Atoi(r.URL.Query().Get("length"))
			if err != nil {
				t.Fatalf("invalid length param %q: %v", r.URL.Query().Get("length"), err)
			}
			if length != pageSize {
				t.Fatalf("length = %d, want %d", length, pageSize)
			}

			end := from + length
			if end > perQuery {
				end = perQuery
			}

			results := make([]map[string]interface{}, 0, end-from)
			for idx := from; idx < end; idx++ {
				deviceNumber := base + idx + 1
				results = append(results, map[string]interface{}{
					"id":        deviceNumber,
					"ipAddress": releaseGateIP(deviceNumber),
					"name":      fmt.Sprintf("armis-release-gate-%d", deviceNumber),
				})
			}

			next := 0
			if end < perQuery {
				next = end
			}

			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(map[string]interface{}{
				"data": map[string]interface{}{
					"count":   len(results),
					"next":    next,
					"prev":    nil,
					"results": results,
					"total":   perQuery,
				},
				"success": true,
			}); err != nil {
				t.Fatalf("encode response: %v", err)
			}
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type:          SourceType,
		Endpoint:      server.URL,
		SyncServiceID: "sync-source-release-gate",
		Credentials:   map[string]string{"secret_key": "secret", "page_size": strconv.Itoa(pageSize)},
		Queries: []models.QueryConfig{
			{Label: "release-gate-a", Query: "in:devices release_gate:a"},
			{Label: "release-gate-b", Query: "in:devices release_gate:b"},
		},
	}, recorder.emit)

	count, err := NewDriver().Sync(context.Background(), run)
	if err != nil {
		t.Fatalf("Sync returned error: %v", err)
	}
	if count != totalDevices {
		t.Fatalf("count = %d, want %d", count, totalDevices)
	}
	expectedTokenCalls := 1
	expectedExtraSearches := 0
	if perQuery > pageSize {
		expectedTokenCalls = 2
		expectedExtraSearches = 1
	}

	if tokenCalls != expectedTokenCalls {
		t.Fatalf("token calls = %d, want %d", tokenCalls, expectedTokenCalls)
	}

	expectedPages := queryCount * ceilDiv(perQuery, pageSize)
	if searchCalls != expectedPages+expectedExtraSearches {
		t.Fatalf(
			"search calls = %d, want %d including unauthorized retries",
			searchCalls,
			expectedPages+expectedExtraSearches,
		)
	}

	if got := recorder.pageCount(); got != expectedPages {
		t.Fatalf("emitted page count = %d, want %d pages", got, expectedPages)
	}

	seen := make(map[string]bool, totalDevices)
	for _, deviceID := range recorder.deviceIDs() {
		if seen[deviceID] {
			t.Fatalf("duplicate device id %q", deviceID)
		}
		seen[deviceID] = true
	}

	if len(seen) != totalDevices {
		t.Fatalf("emitted device count = %d, want %d", len(seen), totalDevices)
	}
}

func TestConfiguredQueriesDropsBlankQueries(t *testing.T) {
	got := configuredQueries([]models.QueryConfig{
		{Label: "blank"},
		{Label: "spaces", Query: "   "},
		{Label: "devices", Query: testDeviceQuery},
	})

	if len(got) != 1 {
		t.Fatalf("query count = %d, want 1", len(got))
	}
	if got[0].Label != "devices" || got[0].Query != testDeviceQuery {
		t.Fatalf("query = %#v", got[0])
	}
}

func TestConfiguredQueriesNormalizesEscapedQuotes(t *testing.T) {
	got := configuredQueries([]models.QueryConfig{
		{Label: "devices", Query: `  in:devices timeFrame:\"7 Days\" boundary:\"All OT Boundaries\"  `},
	})

	if len(got) != 1 {
		t.Fatalf("query count = %d, want 1", len(got))
	}
	if want := `in:devices timeFrame:"7 Days" boundary:"All OT Boundaries"`; got[0].Query != want {
		t.Fatalf("query = %q, want %q", got[0].Query, want)
	}
}

func releaseGateIP(deviceNumber int) string {
	return fmt.Sprintf(
		"10.%d.%d.%d",
		1+((deviceNumber/65536)%200),
		(deviceNumber/256)%256,
		deviceNumber%256,
	)
}

func testEnvInt(name string, fallback int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}

	parsed, err := strconv.Atoi(raw)
	if err != nil || parsed <= 0 {
		return fallback
	}

	return parsed
}

func ceilDiv(left, right int) int {
	return (left + right - 1) / right
}
