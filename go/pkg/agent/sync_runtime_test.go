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
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestArmisAccessTokenUsesSecretKeyCredential(t *testing.T) {
	t.Parallel()

	const expectedToken = "token-1"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != armisAccessTokenPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, armisAccessTokenPath)
		}

		if got := r.Header.Get("Content-Type"); got != "application/x-www-form-urlencoded" {
			t.Fatalf("content-type = %q, want application/x-www-form-urlencoded", got)
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read token request: %v", err)
		}
		if got := strings.TrimSpace(string(body)); got != "secret_key=secret-1" {
			t.Fatalf("body = %q, want secret_key=secret-1", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true,"data":{"access_token":"` + expectedToken + `"}}`))
	}))
	defer server.Close()

	client := newArmisClient(models.SourceConfig{Endpoint: server.URL})
	token, err := client.accessToken(context.Background(), map[string]string{
		"api_key":    " key-1 ",
		"api_secret": " secret-1 ",
	})
	if err != nil {
		t.Fatalf("accessToken returned error: %v", err)
	}
	if token != expectedToken {
		t.Fatalf("token = %q, want %s", token, expectedToken)
	}
}

func TestBuildArmisUpdateMapsSdkAttributesToInventoryFields(t *testing.T) {
	t.Parallel()

	purdue := 2.5
	firstSeen := time.Date(2026, 5, 14, 1, 2, 3, 246357000, time.UTC)
	lastSeen := time.Date(2026, 5, 14, 4, 5, 6, 987654321, time.UTC)
	server := &Server{config: &ServerConfig{AgentID: "agent-1", Partition: "default"}}
	runner := &syncSourceRunner{config: models.SourceConfig{Type: armisSourceType}}

	update := buildArmisUpdate(server, runner, armisDevice{
		DeviceID:          42,
		Display:           "PLC-01",
		Type:              "PLC",
		Category:          "OT",
		Brand:             "Axis Communications",
		Model:             "P1375",
		OSName:            "Linux",
		OSVersion:         "5.15",
		IPv4Addresses:     []string{"10.0.0.2", "10.0.0.3"},
		MacAddresses:      []string{"00:11:22:33:44:55"},
		FirstSeenSnake:    firstSeen,
		LastSeenSnake:     lastSeen,
		RiskLevelSnake:    72,
		Tags:              []string{"managed", "ot"},
		Boundaries:        []map[string]interface{}{{"id": float64(7), "name": "All OT Boundaries"}},
		SerialNumbers:     []string{"SN-123"},
		PurdueLevel:       &purdue,
		Visibility:        "Full",
		NetworkInterfaces: []map[string]interface{}{{"name": "eth0", "mac": "00:11:22:33:44:55"}},
	}, "managed")

	if update["ip"] != "10.0.0.2" {
		t.Fatalf("ip = %q, want first IPv4 address", update["ip"])
	}
	if update["hostname"] != "PLC-01" {
		t.Fatalf("hostname = %q, want display name", update["hostname"])
	}
	if update["type"] != "PLC" {
		t.Fatalf("type = %q, want PLC", update["type"])
	}
	if update["vendor_name"] != "Axis Communications" {
		t.Fatalf("vendor_name = %q, want Axis Communications", update["vendor_name"])
	}
	if update["model"] != "P1375" {
		t.Fatalf("model = %q, want P1375", update["model"])
	}

	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		t.Fatalf("metadata has type %T, want map[string]string", update["metadata"])
	}

	for key, want := range map[string]string{
		"source_device_id": "42",
		"integration_id":   "42",
		"type":             "PLC",
		"device_type":      "PLC",
		"category":         "OT",
		"ipv4_addresses":   "10.0.0.2,10.0.0.3",
		"mac_addresses":    "001122334455",
		"brand":            "Axis Communications",
		"manufacturer":     "Axis Communications",
		"model":            "P1375",
		"os_name":          "Linux",
		"os_version":       "5.15",
		"risk_score":       "72",
		"query_label":      "managed",
		"source_tags":      "managed,ot",
		"boundary_names":   "All OT Boundaries",
		"serial_number":    "SN-123",
		"serial_numbers":   "SN-123",
		"purdue_level":     "2.5",
		"visibility":       "Full",
	} {
		if got := metadata[key]; got != want {
			t.Fatalf("metadata[%q] = %q, want %q", key, got, want)
		}
	}

	for _, key := range []string{
		"armis_device_id",
		"armis_type",
		"armis_category",
		"armis_risk_level",
		"armis_tags",
		"armis_boundary_names",
		"armis_serial_numbers",
		"armis_purdue_level",
		"armis_visibility",
	} {
		if _, ok := metadata[key]; ok {
			t.Fatalf("metadata[%q] should not be emitted; use normalized inventory fields", key)
		}
	}

	if update["first_seen_time"] != "2026-05-14T01:02:03Z" {
		t.Fatalf("first_seen_time = %q", update["first_seen_time"])
	}
	if update["last_seen_time"] != "2026-05-14T04:05:06Z" {
		t.Fatalf("last_seen_time = %q", update["last_seen_time"])
	}
	timestamp, ok := update["timestamp"].(string)
	if !ok {
		t.Fatalf("timestamp has type %T, want string", update["timestamp"])
	}
	if strings.Contains(timestamp, ".") {
		t.Fatalf("timestamp = %q, want second precision", timestamp)
	}
}
