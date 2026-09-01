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

func (e *emitRecorder) updates() []map[string]any {
	e.mu.Lock()
	defer e.mu.Unlock()

	var updates []map[string]any
	for _, page := range e.pages {
		updates = append(updates, page...)
	}

	return updates
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

func TestSyncAccountsAndDeduplicatesAcrossQueries(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case searchPath:
			results := []map[string]interface{}{
				{"id": 101, "ipAddress": "10.0.0.101", "serial_numbers": []string{"SERIAL-A"}},
				{"id": 102, "ipAddress": "10.0.0.102", "serial_numbers": []string{"SERIAL-B"}},
				{"id": 999, "ipAddress": "192.0.2.99", "serial_numbers": []string{"EXCLUDED"}},
			}
			if r.URL.Query().Get("aql") == "in:devices query:b" {
				results = []map[string]interface{}{
					{"id": 101, "ipAddress": "10.0.1.101", "serial_numbers": []string{"serial-a"}},
					{"id": 102, "ipAddress": "10.0.1.102", "serial_numbers": []string{"SERIAL-C"}},
				}
			}

			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"data": map[string]interface{}{
					"count": len(results), "next": 0, "results": results, "total": len(results),
				},
				"success": true,
			})
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	var population syncsources.PopulationStats
	run := testRunContext(models.SourceConfig{
		Type:        SourceType,
		Endpoint:    server.URL,
		Credentials: map[string]string{"secret_key": "secret"},
		Queries: []models.QueryConfig{
			{Label: "query-a", Query: "in:devices query:a"},
			{Label: "query-b", Query: "in:devices query:b"},
		},
		NetworkBlacklist: []string{"192.0.2.0/24"},
	}, recorder.emit)
	run.ReportPopulation = func(stats syncsources.PopulationStats) { population = stats }

	count, err := NewDriver().Sync(context.Background(), run)
	if err != nil {
		t.Fatalf("Sync returned error: %v", err)
	}
	if count != 3 {
		t.Fatalf("emitted update count = %d, want 2 first observations plus 1 conflict marker", count)
	}
	if population.RawRows != 5 || population.ExcludedRows != 1 || population.InvalidRows != 0 || population.ValidOccurrences != 4 {
		t.Fatalf("raw accounting = %#v", population)
	}
	if population.DistinctSourceIDs != 2 || population.DuplicateOccurrences != 2 {
		t.Fatalf("ID accounting = %#v", population)
	}
	if fmt.Sprint(population.ConflictingDuplicateIDs) != "[102]" {
		t.Fatalf("conflicting duplicate IDs = %v, want [102]", population.ConflictingDuplicateIDs)
	}

	var conflictMarkers int
	for _, update := range recorder.updates() {
		metadata, _ := update["metadata"].(map[string]string)
		if metadata["source_duplicate_conflict"] == "true" {
			conflictMarkers++
			if metadata["armis_device_id"] != "102" {
				t.Fatalf("conflict marker attached to ID %q, want 102", metadata["armis_device_id"])
			}
		}
	}
	if conflictMarkers != 1 {
		t.Fatalf("conflict markers = %d, want 1", conflictMarkers)
	}
}

func TestSyncMarksSamePageConflictWithoutEmittingDuplicateUpsert(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case searchPath:
			_, _ = w.Write([]byte(`{
				"data":{"count":2,"next":0,"results":[
					{"id":101,"ipAddress":"10.0.0.101","serial_numbers":["SERIAL-A"]},
					{"id":101,"ipAddress":"10.0.1.101","serial_numbers":["SERIAL-B"]}
				],"total":2},"success":true
			}`))
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type: SourceType, Endpoint: server.URL,
		Credentials: map[string]string{"secret_key": "secret"},
		Queries:     []models.QueryConfig{{Label: "same-page", Query: testDeviceQuery}},
	}, recorder.emit)

	count, err := NewDriver().Sync(context.Background(), run)
	if err != nil {
		t.Fatalf("Sync returned error: %v", err)
	}
	if count != 1 || len(recorder.updates()) != 1 {
		t.Fatalf("emitted %d updates (%d captured), want one unique source-ID upsert", count, len(recorder.updates()))
	}
	metadata, _ := recorder.updates()[0]["metadata"].(map[string]string)
	if metadata["source_duplicate_conflict"] != "true" {
		t.Fatalf("same-page conflict marker missing: %#v", metadata)
	}
}

func TestDuplicateConflictUpdateDropsLargeDescriptiveFields(t *testing.T) {
	update := map[string]interface{}{
		"agent_id":           "agent-a",
		"gateway_id":         "gateway-a",
		"partition":          "partition-a",
		"device_id":          "partition-a:10.0.0.101",
		"ip":                 "10.0.0.101",
		"source":             SourceType,
		"timestamp":          "2026-09-01T08:00:00Z",
		"network_interfaces": []map[string]interface{}{{"name": "eth0"}},
		"metadata": map[string]string{
			"integration_type":   SourceType,
			"armis_device_id":    "101",
			"integration_id":     "101",
			"serial_numbers":     "SERIAL-A",
			"network_interfaces": `[{"name":"eth0"}]`,
			"site":               `{"name":"large-site-payload"}`,
		},
	}

	correction := duplicateConflictUpdate(update)
	if _, exists := correction["network_interfaces"]; exists {
		t.Fatalf("correction retained top-level network interfaces: %#v", correction)
	}
	metadata, _ := correction["metadata"].(map[string]string)
	if _, exists := metadata["network_interfaces"]; exists {
		t.Fatalf("correction retained metadata network interfaces: %#v", metadata)
	}
	if _, exists := metadata["site"]; exists {
		t.Fatalf("correction retained descriptive site metadata: %#v", metadata)
	}
	if metadata["armis_device_id"] != "101" || metadata["source_duplicate_conflict"] != duplicateConflictFlagValue {
		t.Fatalf("correction identity metadata = %#v", metadata)
	}
}

func TestDuplicateIdentityConflictRequiresDisjointValuesForSameField(t *testing.T) {
	tests := []struct {
		name     string
		first    map[string]string
		second   map[string]string
		conflict bool
	}{
		{
			name:  "same serial with added mac is compatible",
			first: map[string]string{"serial_numbers": "SERIAL-A"},
			second: map[string]string{
				"serial_numbers": "serial-a", "mac_addresses": "00:11:22:33:44:55",
			},
		},
		{
			name:   "overlapping interface sets are compatible",
			first:  map[string]string{"mac_addresses": "00:11:22:33:44:55,00:11:22:33:44:66"},
			second: map[string]string{"mac_addresses": "00:11:22:33:44:66"},
		},
		{
			name:     "disjoint serials conflict",
			first:    map[string]string{"serial_numbers": "SERIAL-A"},
			second:   map[string]string{"serial_numbers": "SERIAL-B"},
			conflict: true,
		},
		{
			name:     "disjoint macs conflict",
			first:    map[string]string{"mac_addresses": "00:11:22:33:44:55"},
			second:   map[string]string{"mac_addresses": "00:11:22:33:44:66"},
			conflict: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			first := duplicateIdentitySignature(map[string]interface{}{"metadata": tt.first})
			second := duplicateIdentitySignature(map[string]interface{}{"metadata": tt.second})
			if got := conflictingDuplicateSignature(first, second); got != tt.conflict {
				t.Fatalf("conflict = %v, want %v", got, tt.conflict)
			}
		})
	}
}

func TestDuplicateIdentityMergeRetainsLaterEvidence(t *testing.T) {
	empty := duplicateIdentitySignature(map[string]interface{}{"metadata": map[string]string{}})
	serialA := duplicateIdentitySignature(map[string]interface{}{
		"metadata": map[string]string{"serial_numbers": "SERIAL-A"},
	})
	serialB := duplicateIdentitySignature(map[string]interface{}{
		"metadata": map[string]string{"serial_numbers": "SERIAL-B"},
	})

	merged := mergeDuplicateIdentity(empty, serialA)
	if !conflictingDuplicateSignature(merged, serialB) {
		t.Fatal("later disjoint evidence should conflict even when the first repeat had no anchors")
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

func TestSyncEnrichesConfiguredArmisAssetFields(t *testing.T) {
	var (
		v1SearchCalls int
		v3SearchCalls int
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"v1-token"},"success":true}`))
		case v3OAuthTokenPath:
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatalf("decode v3 token payload: %v", err)
			}
			if payload["client_id"] != "client@example.invalid" {
				t.Fatalf("client_id = %v", payload["client_id"])
			}
			if payload["vendor_id"] != "vendor-1" {
				t.Fatalf("vendor_id = %v", payload["vendor_id"])
			}

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"access_token":"v3-token"}`))
		case searchPath:
			v1SearchCalls++
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"data":{
					"count":1,
					"next":0,
					"prev":null,
					"results":[
						{"id":101,"ipAddress":"10.0.4.40","name":"fsfo027c.global.example.com"}
					],
					"total":1
				},
				"success":true
			}`))
		case v3AssetSearchPath:
			v3SearchCalls++
			if got := r.Header.Get("Authorization"); got != "Bearer v3-token" {
				t.Fatalf("v3 authorization = %q", got)
			}

			var payload struct {
				AssetType string   `json:"asset_type"`
				Fields    []string `json:"fields"`
				Filter    struct {
					FilterCriteria string `json:"filter_criteria"`
					AssetIDSource  string `json:"asset_id_source"`
					AssetIDs       []int  `json:"asset_ids"`
				} `json:"filter"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatalf("decode v3 asset payload: %v", err)
			}
			if payload.AssetType != "DEVICE" {
				t.Fatalf("asset_type = %q", payload.AssetType)
			}
			if payload.Filter.FilterCriteria != "ASSET_ID" || payload.Filter.AssetIDSource != "ASSET_ID" {
				t.Fatalf("unexpected filter: %#v", payload.Filter)
			}
			if len(payload.Filter.AssetIDs) != 1 || payload.Filter.AssetIDs[0] != 101 {
				t.Fatalf("asset_ids = %#v", payload.Filter.AssetIDs)
			}
			if !stringSliceContains(payload.Fields, "accessSwitch") || !stringSliceContains(payload.Fields, "vlans") {
				t.Fatalf("fields = %#v, want accessSwitch and vlans", payload.Fields)
			}

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"items": [
					{
						"asset_id": 101,
						"fields": {
							"accessSwitch": "nsfocs-idfer1-asw001:2/20",
							"vlans": [3006]
						}
					}
				],
				"next": null
			}`))
		default:
			t.Fatalf("unexpected path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	recorder := &emitRecorder{}
	run := testRunContext(models.SourceConfig{
		Type:     SourceType,
		Endpoint: server.URL,
		Credentials: map[string]string{
			"secret_key":    "secret",
			"client_id":     "client@example.invalid",
			"client_secret": "client-secret",
			"vendor_id":     "vendor-1",
		},
		Settings: map[string]any{
			"asset_fields": []any{"accessSwitch", "vlans"},
			"v3_endpoint":  server.URL,
		},
		Queries: []models.QueryConfig{{Label: "test", Query: testDeviceQuery}},
	}, recorder.emit)

	count, err := NewDriver().Sync(context.Background(), run)
	if err != nil {
		t.Fatalf("Sync returned error: %v", err)
	}
	if count != 1 {
		t.Fatalf("count = %d, want 1", count)
	}
	if v1SearchCalls != 1 {
		t.Fatalf("v1 search calls = %d, want 1", v1SearchCalls)
	}
	if v3SearchCalls != 1 {
		t.Fatalf("v3 search calls = %d, want 1", v3SearchCalls)
	}

	updates := recorder.updates()
	if len(updates) != 1 {
		t.Fatalf("updates = %d, want 1", len(updates))
	}
	metadata, ok := updates[0]["metadata"].(map[string]string)
	if !ok {
		t.Fatalf("metadata has type %T, want map[string]string", updates[0]["metadata"])
	}
	if got := metadata["armis_access_switch"]; got != "nsfocs-idfer1-asw001:2/20" {
		t.Fatalf("metadata[armis_access_switch] = %q", got)
	}
	if got := metadata["armis_vlans"]; got != "[3006]" {
		t.Fatalf("metadata[armis_vlans] = %q", got)
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

func stringSliceContains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}

	return false
}
