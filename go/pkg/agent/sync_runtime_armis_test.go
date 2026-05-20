package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const testArmisDeviceQuery = "in:devices"

func TestArmisAccessTokenUsesFormEncodedSecretKey(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != armisAccessTokenPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, armisAccessTokenPath)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("method = %q, want POST", r.Method)
		}
		if got := r.Header.Get("Content-Type"); got != "application/x-www-form-urlencoded" {
			t.Fatalf("content-type = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("accept = %q", got)
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if got := string(body); got != "secret_key=secret-value" {
			t.Fatalf("body = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	token, err := client.accessToken(context.Background(), map[string]string{
		"api_key":    "ignored-key",
		"api_secret": "secret-value",
	})
	if err != nil {
		t.Fatalf("accessToken returned error: %v", err)
	}
	if token != "token-123" {
		t.Fatalf("token = %q", token)
	}
}

func TestArmisAccessTokenIncludesErrorBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "Invalid secret key", http.StatusBadRequest)
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	_, err := client.accessToken(context.Background(), map[string]string{"secret_key": "bad"})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "Invalid secret key") {
		t.Fatalf("error = %q", err)
	}
}

func TestArmisSecretKeyPreference(t *testing.T) {
	got := armisSecretKey(map[string]string{
		"secret_key": "  preferred ",
		"api_secret": "secondary",
		"api_key":    "last",
	})
	if got != "preferred" {
		t.Fatalf("secret key = %q", got)
	}
}

func TestArmisSearchUsesRawAccessToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != armisSearchPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, armisSearchPath)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("method = %q, want GET", r.Method)
		}
		if got := r.Header.Get("Authorization"); got != "token-123" {
			t.Fatalf("authorization = %q, want raw access token", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("accept = %q", got)
		}
		if got := r.URL.Query().Get("aql"); got != testArmisDeviceQuery {
			t.Fatalf("aql = %q", got)
		}
		if got := r.URL.Query().Get("from"); got != "10" {
			t.Fatalf("from = %q", got)
		}
		if got := r.URL.Query().Get("length"); got != "25" {
			t.Fatalf("length = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"count":0,"next":0,"prev":null,"results":[],"total":0},"success":true}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	resp, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 10, 25)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if resp == nil || !resp.Success {
		t.Fatalf("search response = %#v", resp)
	}
}

func TestArmisSearchAcceptsScalarDeviceNames(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != armisSearchPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, armisSearchPath)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"data": {
				"count": 2,
				"next": 0,
				"prev": null,
				"total": 2,
				"results": [
					{"id": 101, "ipAddress": "192.0.2.10", "names": "scalar-name"},
					{"id": 102, "ipAddress": "192.0.2.11", "names": ["array-name"]}
				]
			},
			"success": true
		}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	resp, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 0, 100)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if len(resp.Data.Results) != 2 {
		t.Fatalf("result count = %d, want 2", len(resp.Data.Results))
	}
	if got := resp.Data.Results[0].primaryName(); got != "scalar-name" {
		t.Fatalf("scalar primaryName = %q, want scalar-name", got)
	}
	if got := resp.Data.Results[1].primaryName(); got != "array-name" {
		t.Fatalf("array primaryName = %q, want array-name", got)
	}
}

func TestArmisSearchOmitsFromOnFirstPage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := r.URL.Query()["from"]; ok {
			t.Fatalf("from query param should be omitted on first page, got %q", r.URL.RawQuery)
		}
		if got := r.URL.Query().Get("aql"); got != testArmisDeviceQuery {
			t.Fatalf("aql = %q", got)
		}
		if got := r.URL.Query().Get("length"); got != "100" {
			t.Fatalf("length = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"count":0,"next":0,"prev":null,"results":[],"total":0},"success":true}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	resp, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 0, 100)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if resp == nil || !resp.Success {
		t.Fatalf("search response = %#v", resp)
	}
}

func TestArmisSearchErrorIncludesBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "bad aql", http.StatusBadRequest)
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	_, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 0, 100)
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "bad aql") {
		t.Fatalf("error = %q", err)
	}
}

func TestRunArmisSyncStreamsFetchedPagesBeforeLaterSearchError(t *testing.T) {
	var searchCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case armisAccessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case armisSearchPath:
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

	gateway := &fakeSyncGateway{}
	runtime := &SyncRuntime{
		server:  &Server{config: &ServerConfig{AgentID: "agent-a", Partition: "partition-a"}},
		gateway: gateway,
		logger:  createTestLogger(),
	}
	runner := &syncSourceRunner{
		key: "armis",
		config: models.SourceConfig{
			Type:        armisSourceType,
			Endpoint:    server.URL,
			Credentials: map[string]string{"secret_key": "secret", "page_size": "2"},
			Queries:     []models.QueryConfig{{Label: "test", Query: testArmisDeviceQuery}},
		},
	}

	count, err := runtime.runArmisSync(context.Background(), runner, "run-123")
	if err == nil {
		t.Fatal("expected second page error")
	}
	if !strings.Contains(err.Error(), "second page failed") {
		t.Fatalf("error = %q", err)
	}
	if count != 2 {
		t.Fatalf("count = %d, want flushed first page count", count)
	}
	if searchCalls != 2 {
		t.Fatalf("search calls = %d, want 2", searchCalls)
	}

	chunks := gateway.chunks()
	if len(chunks) == 0 {
		t.Fatal("expected first page to be streamed before second page error")
	}

	gotDevices := decodedSyncChunkDeviceIDs(t, chunks)
	wantDevices := map[string]bool{"partition-a:10.0.0.101": true, "partition-a:10.0.0.102": true}
	for _, deviceID := range gotDevices {
		delete(wantDevices, deviceID)
	}
	if len(wantDevices) != 0 {
		t.Fatalf("missing streamed devices: %v; got %v", wantDevices, gotDevices)
	}
}

func TestRunArmisSyncRefreshesAccessTokenOnSearchUnauthorized(t *testing.T) {
	const pageSize = 2

	var (
		mu          sync.Mutex
		tokenCalls  int
		searchCalls int
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case armisAccessTokenPath:
			mu.Lock()
			tokenCalls++
			token := "token-" + strconv.Itoa(tokenCalls)
			mu.Unlock()

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"` + token + `"},"success":true}`))
		case armisSearchPath:
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

	gateway := &fakeSyncGateway{}
	runtime := &SyncRuntime{
		server:  &Server{config: &ServerConfig{AgentID: "agent-a", Partition: "partition-a"}},
		gateway: gateway,
		logger:  createTestLogger(),
	}
	runner := &syncSourceRunner{
		key: "armis",
		config: models.SourceConfig{
			Type:        armisSourceType,
			Endpoint:    server.URL,
			Credentials: map[string]string{"secret_key": "secret", "page_size": strconv.Itoa(pageSize)},
			Queries:     []models.QueryConfig{{Label: "test", Query: testArmisDeviceQuery}},
		},
	}

	count, err := runtime.runArmisSync(context.Background(), runner, "run-123")
	if err != nil {
		t.Fatalf("runArmisSync returned error: %v", err)
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

	gotDevices := decodedSyncChunkDeviceIDs(t, gateway.chunks())
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
		t.Fatalf("missing streamed devices: %v; got %v", wantDevices, gotDevices)
	}
}

func TestRunArmisSyncStreamsLargePagedDatasetAsGatewayResults(t *testing.T) {
	const (
		totalDevices = 250
		pageSize     = 100
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case armisAccessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case armisSearchPath:
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

	gateway := &fakeSyncGateway{}
	runtime := &SyncRuntime{
		server:  &Server{config: &ServerConfig{AgentID: "agent-a", Partition: "partition-a"}},
		gateway: gateway,
		logger:  createTestLogger(),
	}
	runner := &syncSourceRunner{
		key: "armis",
		config: models.SourceConfig{
			Type:          armisSourceType,
			Endpoint:      server.URL,
			SyncServiceID: "sync-source-1",
			Credentials:   map[string]string{"secret_key": "secret", "page_size": strconv.Itoa(pageSize)},
			Queries:       []models.QueryConfig{{Label: "test", Query: testArmisDeviceQuery}},
		},
	}

	count, err := runtime.runArmisSync(context.Background(), runner, "run-123")
	if err != nil {
		t.Fatalf("runArmisSync returned error: %v", err)
	}
	if count != totalDevices {
		t.Fatalf("count = %d, want %d", count, totalDevices)
	}

	streams := gateway.streamsSnapshot()
	if len(streams) != 3 {
		t.Fatalf("stream count = %d, want 3 pages", len(streams))
	}

	seen := make(map[string]bool, totalDevices)
	for streamIdx, stream := range streams {
		if len(stream) == 0 {
			t.Fatalf("stream %d was empty", streamIdx)
		}
		for chunkIdx, chunk := range stream {
			assertGatewayResultsChunk(t, streamIdx, chunkIdx, len(stream), chunk)
			for _, deviceID := range decodedSyncChunkDeviceIDs(t, []*proto.GatewayStatusChunk{chunk}) {
				if seen[deviceID] {
					t.Fatalf("duplicate device id %q", deviceID)
				}
				seen[deviceID] = true
			}
		}
		lastChunk := stream[len(stream)-1]
		if !lastChunk.IsFinal {
			t.Fatalf("stream %d last chunk is not final", streamIdx)
		}
		if streamIdx == len(streams)-1 {
			assertSyncChunkRunFinal(t, lastChunk, true)
			assertSyncChunkRunTotal(t, lastChunk, totalDevices)
		} else {
			assertSyncChunkRunFinal(t, lastChunk, false)
		}
	}

	if len(seen) != totalDevices {
		t.Fatalf("streamed device count = %d, want %d", len(seen), totalDevices)
	}

	finalStream := streams[len(streams)-1]
	assertSyncChunkRunTotal(t, finalStream[len(finalStream)-1], totalDevices)
}

func TestRunArmisSyncReleaseGateStreamsMultipleQueriesAndRefreshesToken(t *testing.T) {
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
		case armisAccessTokenPath:
			mu.Lock()
			tokenCalls++
			token := "token-" + strconv.Itoa(tokenCalls)
			mu.Unlock()

			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"` + token + `"},"success":true}`))
		case armisSearchPath:
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
					"ipAddress": releaseGateArmisIP(deviceNumber),
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

	gateway := &fakeSyncGateway{}
	runtime := &SyncRuntime{
		server:  &Server{config: &ServerConfig{AgentID: "agent-a", Partition: "partition-a"}},
		gateway: gateway,
		logger:  createTestLogger(),
	}
	runner := &syncSourceRunner{
		key: "armis",
		config: models.SourceConfig{
			Type:          armisSourceType,
			Endpoint:      server.URL,
			SyncServiceID: "sync-source-release-gate",
			Credentials:   map[string]string{"secret_key": "secret", "page_size": strconv.Itoa(pageSize)},
			Queries: []models.QueryConfig{
				{Label: "release-gate-a", Query: "in:devices release_gate:a"},
				{Label: "release-gate-b", Query: "in:devices release_gate:b"},
			},
		},
	}

	count, err := runtime.runArmisSync(context.Background(), runner, "run-release-gate")
	if err != nil {
		t.Fatalf("runArmisSync returned error: %v", err)
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

	streams := gateway.streamsSnapshot()
	if len(streams) != expectedPages {
		t.Fatalf("stream count = %d, want %d pages", len(streams), expectedPages)
	}

	seen := make(map[string]bool, totalDevices)
	for streamIdx, stream := range streams {
		if len(stream) == 0 {
			t.Fatalf("stream %d was empty", streamIdx)
		}
		for chunkIdx, chunk := range stream {
			assertGatewayResultsChunk(t, streamIdx, chunkIdx, len(stream), chunk)
			for _, deviceID := range decodedSyncChunkDeviceIDs(t, []*proto.GatewayStatusChunk{chunk}) {
				if seen[deviceID] {
					t.Fatalf("duplicate device id %q", deviceID)
				}
				seen[deviceID] = true
			}
		}
	}

	if len(seen) != totalDevices {
		t.Fatalf("streamed device count = %d, want %d", len(seen), totalDevices)
	}
}

func TestFilterArmisDevicesNormalizesCommaSeparatedIPs(t *testing.T) {
	got := filterArmisDevices([]armisDevice{
		{ID: 101, IPAddress: "10.122.77.227, 10.65.210.86", Name: "multi-ip"},
	}, nil)

	if len(got) != 1 {
		t.Fatalf("filtered device count = %d, want 1", len(got))
	}
	if got[0].IPAddress != "10.122.77.227" {
		t.Fatalf("filtered IP = %q, want first valid IP", got[0].IPAddress)
	}
	if got[0].ID != 101 {
		t.Fatalf("expected normalized device to preserve Armis identity: %#v", got)
	}
}

func TestFilterArmisDevicesDropsBlacklistedCommaSeparatedIPs(t *testing.T) {
	got := filterArmisDevices([]armisDevice{
		{ID: 101, IPAddress: "10.122.77.227, 10.65.210.86", Name: "all-blacklisted"},
		{ID: 102, IPAddress: "10.122.77.228, 192.0.2.10", Name: "mixed"},
		{ID: 103, IPAddress: "not-an-ip", Name: "invalid"},
	}, []string{"192.0.2.0/24", "198.51.100.0/24"})

	if len(got) != 1 {
		t.Fatalf("filtered device count = %d, want 1: %#v", len(got), got)
	}
	if got[0].ID != 102 || got[0].IPAddress != "192.0.2.10" {
		t.Fatalf("filtered device = %#v, want allowed IP from mixed device", got[0])
	}
}

func TestConfiguredArmisQueriesDropsBlankQueries(t *testing.T) {
	got := configuredArmisQueries([]models.QueryConfig{
		{Label: "blank"},
		{Label: "spaces", Query: "   "},
		{Label: "devices", Query: testArmisDeviceQuery},
	})

	if len(got) != 1 {
		t.Fatalf("query count = %d, want 1", len(got))
	}
	if got[0].Label != "devices" || got[0].Query != testArmisDeviceQuery {
		t.Fatalf("query = %#v", got[0])
	}
}

func TestConfiguredArmisQueriesNormalizesEscapedQuotes(t *testing.T) {
	got := configuredArmisQueries([]models.QueryConfig{
		{Label: "devices", Query: `  in:devices timeFrame:\"7 Days\" boundary:\"All OT Boundaries\"  `},
	})

	if len(got) != 1 {
		t.Fatalf("query count = %d, want 1", len(got))
	}
	if want := `in:devices timeFrame:"7 Days" boundary:"All OT Boundaries"`; got[0].Query != want {
		t.Fatalf("query = %q, want %q", got[0].Query, want)
	}
}

type fakeSyncGateway struct {
	mu      sync.Mutex
	streams [][]*proto.GatewayStatusChunk
}

func (f *fakeSyncGateway) StreamStatus(
	_ context.Context,
	chunks []*proto.GatewayStatusChunk,
) (*proto.GatewayStatusResponse, error) {
	if len(chunks) > 0 && !chunks[len(chunks)-1].IsFinal {
		return nil, fmt.Errorf("stream ended without final chunk")
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	copied := append([]*proto.GatewayStatusChunk(nil), chunks...)
	f.streams = append(f.streams, copied)
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func (*fakeSyncGateway) GetGatewayID() string {
	return "gateway-a"
}

func (f *fakeSyncGateway) chunks() []*proto.GatewayStatusChunk {
	f.mu.Lock()
	defer f.mu.Unlock()
	var chunks []*proto.GatewayStatusChunk
	for _, stream := range f.streams {
		chunks = append(chunks, stream...)
	}
	return chunks
}

func (f *fakeSyncGateway) streamsSnapshot() [][]*proto.GatewayStatusChunk {
	f.mu.Lock()
	defer f.mu.Unlock()

	streams := make([][]*proto.GatewayStatusChunk, 0, len(f.streams))
	for _, stream := range f.streams {
		streams = append(streams, append([]*proto.GatewayStatusChunk(nil), stream...))
	}

	return streams
}

func assertGatewayResultsChunk(
	t *testing.T,
	streamIdx int,
	chunkIdx int,
	streamLen int,
	chunk *proto.GatewayStatusChunk,
) {
	t.Helper()

	if chunk.AgentId != "agent-a" {
		t.Fatalf("stream %d chunk %d agent_id = %q", streamIdx, chunkIdx, chunk.AgentId)
	}
	if chunk.GatewayId != "gateway-a" {
		t.Fatalf("stream %d chunk %d gateway_id = %q", streamIdx, chunkIdx, chunk.GatewayId)
	}
	if chunk.Partition != "partition-a" {
		t.Fatalf("stream %d chunk %d partition = %q", streamIdx, chunkIdx, chunk.Partition)
	}
	if chunk.TotalChunks <= 0 {
		t.Fatalf("stream %d chunk %d total_chunks = %d", streamIdx, chunkIdx, chunk.TotalChunks)
	}
	if chunk.ChunkIndex != int32(chunkIdx) {
		t.Fatalf("stream %d chunk %d chunk_index = %d", streamIdx, chunkIdx, chunk.ChunkIndex)
	}
	if int(chunk.TotalChunks) != streamLen {
		t.Fatalf("stream %d chunk %d has inconsistent total_chunks = %d", streamIdx, chunkIdx, chunk.TotalChunks)
	}
	if len(chunk.Services) != 1 {
		t.Fatalf("stream %d chunk %d service count = %d, want 1", streamIdx, chunkIdx, len(chunk.Services))
	}

	service := chunk.Services[0]
	if service.ServiceName != syncServiceName {
		t.Fatalf("stream %d chunk %d service_name = %q", streamIdx, chunkIdx, service.ServiceName)
	}
	if service.ServiceType != syncServiceType {
		t.Fatalf("stream %d chunk %d service_type = %q", streamIdx, chunkIdx, service.ServiceType)
	}
	if service.Source != "results" {
		t.Fatalf("stream %d chunk %d source = %q", streamIdx, chunkIdx, service.Source)
	}
	if service.AgentId != chunk.AgentId {
		t.Fatalf("stream %d chunk %d service agent_id = %q", streamIdx, chunkIdx, service.AgentId)
	}
	if service.GatewayId != chunk.GatewayId {
		t.Fatalf("stream %d chunk %d service gateway_id = %q", streamIdx, chunkIdx, service.GatewayId)
	}
	if len(service.Message) == 0 {
		t.Fatalf("stream %d chunk %d service message is empty", streamIdx, chunkIdx)
	}
}

func decodedSyncChunkDeviceIDs(t *testing.T, chunks []*proto.GatewayStatusChunk) []string {
	t.Helper()
	var deviceIDs []string
	for i, chunk := range chunks {
		for j, service := range chunk.Services {
			var updates []map[string]interface{}
			if err := json.Unmarshal(service.Message, &updates); err != nil {
				t.Fatalf("decode chunk %d service %d: %v", i, j, err)
			}
			for _, update := range updates {
				deviceID, _ := update["device_id"].(string)
				if deviceID == "" {
					t.Fatalf("missing device_id in update: %#v", update)
				}
				deviceIDs = append(deviceIDs, deviceID)
				metadata, ok := update["metadata"].(map[string]interface{})
				if !ok {
					t.Fatalf("missing metadata in update: %#v", update)
				}
				rawSourceID, _ := metadata["source_device_id"].(string)
				if _, err := strconv.Atoi(rawSourceID); err != nil {
					t.Fatalf("invalid source_device_id %q: %v", rawSourceID, err)
				}
			}
		}
	}
	return deviceIDs
}

func assertSyncChunkRunTotal(t *testing.T, chunk *proto.GatewayStatusChunk, want int) {
	t.Helper()
	meta := syncMetaFromFinalUpdate(t, chunk)

	got, ok := meta["total_devices"].(float64)
	if !ok {
		t.Fatalf("sync_meta total_devices = %#v", meta["total_devices"])
	}
	if int(got) != want {
		t.Fatalf("sync_meta total_devices = %d, want %d", int(got), want)
	}
}

func assertSyncChunkRunFinal(t *testing.T, chunk *proto.GatewayStatusChunk, want bool) {
	t.Helper()
	meta := syncMetaFromFinalUpdate(t, chunk)

	got, ok := meta["is_final"].(bool)
	if !ok {
		t.Fatalf("sync_meta is_final = %#v", meta["is_final"])
	}
	if got != want {
		t.Fatalf("sync_meta is_final = %t, want %t", got, want)
	}
}

func syncMetaFromFinalUpdate(t *testing.T, chunk *proto.GatewayStatusChunk) map[string]interface{} {
	t.Helper()
	if len(chunk.Services) == 0 {
		t.Fatal("final chunk has no services")
	}

	var updates []map[string]interface{}
	if err := json.Unmarshal(chunk.Services[0].Message, &updates); err != nil {
		t.Fatalf("decode final chunk: %v", err)
	}
	if len(updates) == 0 {
		t.Fatal("final chunk has no updates")
	}

	meta, ok := updates[len(updates)-1]["sync_meta"].(map[string]interface{})
	if !ok {
		t.Fatalf("final update missing sync_meta: %#v", updates[len(updates)-1])
	}

	return meta
}

func releaseGateArmisIP(deviceNumber int) string {
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

func TestScheduledSyncRunPrefersDiscoveryInterval(t *testing.T) {
	interval, kind, ok := scheduledSyncRun(models.SourceConfig{
		PollInterval:      models.Duration(5 * time.Minute),
		DiscoveryInterval: models.Duration(time.Hour),
	})

	if !ok {
		t.Fatal("expected schedule")
	}
	if interval != time.Hour {
		t.Fatalf("interval = %v, want 1h", interval)
	}
	if kind != "discovery" {
		t.Fatalf("kind = %q, want discovery", kind)
	}
}

func TestScheduledSyncRunFallsBackToPollInterval(t *testing.T) {
	interval, kind, ok := scheduledSyncRun(models.SourceConfig{
		PollInterval: models.Duration(5 * time.Minute),
	})

	if !ok {
		t.Fatal("expected schedule")
	}
	if interval != 5*time.Minute {
		t.Fatalf("interval = %v, want 5m", interval)
	}
	if kind != "poll" {
		t.Fatalf("kind = %q, want poll", kind)
	}
}

func TestClaimInitialSyncRunThrottlesRecentSameConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync-runtime-runs.json")
	now := time.Date(2026, 5, 13, 3, 0, 0, 0, time.UTC)

	claimed, err := claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now)
	if err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("first claim should run")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now.Add(5*time.Minute))
	if err != nil {
		t.Fatalf("second claim returned error: %v", err)
	}
	if claimed {
		t.Fatal("second claim should be throttled")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now.Add(time.Hour))
	if err != nil {
		t.Fatalf("third claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("claim after interval should run")
	}
}

func TestClaimInitialSyncRunAllowsChangedConfigHash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync-runtime-runs.json")
	now := time.Date(2026, 5, 13, 3, 0, 0, 0, time.UTC)

	claimed, err := claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now)
	if err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("first claim should run")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-b", time.Hour, now.Add(5*time.Minute))
	if err != nil {
		t.Fatalf("changed hash claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("changed config hash should run immediately")
	}
}
