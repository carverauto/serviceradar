package main

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
	"testing"

	"github.com/stretchr/testify/require"
)

func TestProduceFixtureUsesRealArmisDriverPaginationAndNormalization(t *testing.T) {
	var churnRequests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/access_token/":
			_, _ = w.Write([]byte(`{"success":true,"data":{"access_token":"fixture-token"}}`))
		case "/api/v1/search/":
			from, _ := strconv.Atoi(r.URL.Query().Get("from"))
			if from == 0 && r.URL.Query().Get("from") == "" {
				from = 0
			}
			if from >= 3 {
				_, _ = w.Write([]byte(`{"success":true,"data":{"count":0,"next":0,"total":3,"results":[]}}`))
				return
			}
			id := from + 1
			next := 0
			if id < 3 {
				next = id
			}
			body := map[string]interface{}{
				"success": true,
				"data": map[string]interface{}{
					"count": 1,
					"next":  next,
					"total": 3,
					"results": []map[string]interface{}{{
						"id":           id,
						"ipAddress":    "10.0.0." + strconv.Itoa(id),
						"macAddress":   fmt.Sprintf("AA-BB-CC-DD-EE-%02X", id),
						"name":         "device-" + strconv.Itoa(id),
						"type":         "server",
						"manufacturer": "fixture",
					}},
				},
			}
			_ = json.NewEncoder(w).Encode(body)
		case "/debug/armis/simulation/churn":
			churnRequests++
			_, _ = w.Write([]byte(`{"success":true,"data":{"changed_devices":2}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	output := filepath.Join(t.TempDir(), "fixture.jsonl")
	summary, err := produceFixture(context.Background(), fixtureOptions{
		Endpoint:         server.URL,
		Output:           output,
		SourceID:         defaultSourceID,
		RunID:            defaultRunID,
		PageSize:         1,
		ChurnSwaps:       2,
		RepeatAfterChurn: true,
		HTTPClient:       server.Client(),
	})
	require.NoError(t, err)
	require.Equal(t, 1, churnRequests)
	require.Equal(t, 6, summary.Updates)
	require.Equal(t, 6, summary.Pages)

	file, err := os.Open(output)
	require.NoError(t, err)
	defer func() { _ = file.Close() }()

	decoder := json.NewDecoder(file)
	var pages []fixturePage
	for {
		var page fixturePage
		err := decoder.Decode(&page)
		if err == io.EOF {
			break
		}
		require.NoError(t, err)
		pages = append(pages, page)
	}
	require.Len(t, pages, 6)
	for _, page := range pages {
		require.Len(t, page.Updates, 1)
		update := page.Updates[0]
		require.Equal(t, strconv.Itoa((page.Page%3)+1), update["metadata"].(map[string]interface{})["armis_device_id"])
		require.Equal(t, "AA-BB-CC-DD-EE-0"+strconv.Itoa((page.Page%3)+1), update["mac"])
		require.Equal(
			t,
			"AABBCCDDEE0"+strconv.Itoa((page.Page%3)+1),
			update["metadata"].(map[string]interface{})["mac_addresses"],
		)
	}
}
