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

package core

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/carverauto/serviceradar/pkg/models"
)

// TestSweepJSONParsing tests the core JSON parsing logic that our fix implements
func TestSweepJSONParsing(t *testing.T) {
	tests := []struct {
		name              string
		serviceData       string
		expectedHostCount int
		expectedError     bool
		description       string
	}{
		{
			name: "single_json_object",
			serviceData: `{
				"poller_id": "demo-staging",
				"agent_id": "default-agent",
				"network": "192.168.1.0/24",
				"total_hosts": 2,
				"available_hosts": 1,
				"last_sweep": 1735857600,
				"hosts": [
					{
						"host": "192.168.1.1",
						"available": true,
						"first_seen": "2025-01-02T20:00:00Z",
						"last_seen": "2025-01-02T20:00:00Z",
						"response_time": 1000000
					}
				]
			}`,
			expectedHostCount: 1,
			expectedError:     false,
			description:       "Single JSON object should parse successfully",
		},
		{
			name: "concatenated_json_objects",
			serviceData: `{
				"poller_id": "demo-staging",
				"agent_id": "default-agent",
				"network": "192.168.1.0/24",
				"total_hosts": 1,
				"available_hosts": 0,
				"last_sweep": 1735857600,
				"hosts": []
			}{
				"poller_id": "demo-staging",
				"agent_id": "local-agent",
				"network": "192.168.1.0/24",
				"total_hosts": 3,
				"available_hosts": 2,
				"last_sweep": 1735857600,
				"hosts": [
					{
						"host": "192.168.1.1",
						"available": true,
						"first_seen": "2025-01-02T20:00:00Z",
						"last_seen": "2025-01-02T20:00:00Z",
						"response_time": 1000000
					},
					{
						"host": "192.168.1.2",
						"available": true,
						"first_seen": "2025-01-02T20:00:00Z",
						"last_seen": "2025-01-02T20:00:00Z",
						"response_time": 2000000
					}
				]
			}`,
			expectedHostCount: 2,
			expectedError:     false,
			description:       "Concatenated JSON objects should be parsed and hosts combined",
		},
		{
			name: "real_world_scenario",
			serviceData: `{"poller_id":"demo-staging","agent_id":"default-agent","network":"192.168.1.0/24",` +
				`"total_hosts":256,"available_hosts":0,"last_sweep":1735857600,"ports":[],"hosts":[]}` +
				`{"poller_id":"demo-staging","agent_id":"local-agent","network":"192.168.1.0/24",` +
				`"total_hosts":256,"available_hosts":3,"last_sweep":1735857600,"ports":[],` +
				`"hosts":[{"host":"192.168.1.1","available":true,` +
				`"first_seen":"2025-01-02T20:00:00Z","last_seen":"2025-01-02T20:00:00Z","response_time":1000000},` +
				`{"host":"192.168.1.100","available":true,` +
				`"first_seen":"2025-01-02T20:00:00Z","last_seen":"2025-01-02T20:00:00Z","response_time":1500000},` +
				`{"host":"192.168.1.254","available":true,` +
				`"first_seen":"2025-01-02T20:00:00Z","last_seen":"2025-01-02T20:00:00Z","response_time":2000000}]}`,
			expectedHostCount: 3,
			expectedError:     false,
			description:       "Real world concatenated JSON should parse correctly",
		},
		{
			name:              "invalid_json",
			serviceData:       `{"invalid": json}`,
			expectedHostCount: 0,
			expectedError:     true,
			description:       "Invalid JSON should return an error",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// This test replicates the core parsing logic from our fix
			var sweepSummary models.SweepSummary

			serviceData := json.RawMessage(tt.serviceData)

			// Try to parse as a single JSON object first
			err := json.Unmarshal(serviceData, &sweepSummary)
			if err != nil {
				// If single object parsing fails, try to parse as multiple concatenated JSON objects
				decoder := json.NewDecoder(strings.NewReader(string(serviceData)))

				var allHosts []models.HostResult

				var lastSummary *models.SweepSummary

				var parseError error

				for decoder.More() {
					var chunkData models.SweepSummary
					if chunkErr := decoder.Decode(&chunkData); chunkErr != nil {
						parseError = chunkErr
						break
					}

					// Accumulate hosts from all chunks
					allHosts = append(allHosts, chunkData.Hosts...)
					// Use the last chunk's summary data
					lastSummary = &chunkData
				}

				if parseError != nil {
					if tt.expectedError {
						// Expected error case
						assert.Error(t, parseError, tt.description)
						return
					}

					t.Fatalf("Failed to decode chunk: %v", parseError)
				}

				// Combine all the data
				if lastSummary != nil {
					sweepSummary = *lastSummary
				}

				sweepSummary.Hosts = allHosts
			}

			// Verify expectations
			if tt.expectedError {
				t.Fatalf("Expected an error but parsing succeeded with %d hosts", len(sweepSummary.Hosts))
			} else {
				assert.Len(t, sweepSummary.Hosts, tt.expectedHostCount,
					"Expected %d hosts, got %d. %s",
					tt.expectedHostCount, len(sweepSummary.Hosts), tt.description)

				// Verify host data integrity for the real world scenario
				if tt.name == "real_world_scenario" {
					expectedHosts := []string{"192.168.1.1", "192.168.1.100", "192.168.1.254"}
					actualHosts := make([]string, len(sweepSummary.Hosts))

					for i, host := range sweepSummary.Hosts {
						actualHosts[i] = host.Host
					}

					assert.ElementsMatch(t, expectedHosts, actualHosts, "Should have correct host IPs")

					// Verify all hosts are marked as available
					for i, host := range sweepSummary.Hosts {
						assert.True(t, host.Available, "Host %d should be marked as available", i)
					}
				}
			}
		})
	}
}
