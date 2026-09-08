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

package addon

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestProducerScheduleContractSerializesGenericManifestShape(t *testing.T) {
	contract := NewProducerScheduleContract("advisory.refresh", "Refresh advisory feed", "advisory.refresh").
		WithDescription("Downloads and emits normalized advisory batches").
		WithCadence(21_600, 3_600, 2_592_000).
		WithCron("0 */6 * * *").
		WithJitterSeconds(120).
		WithSettingsSchema(map[string]any{
			"type": "object",
			"properties": map[string]any{
				"feed_key": map[string]any{
					"type":        "string",
					"title":       "Feed key",
					"description": "Producer-owned feed selector",
				},
			},
			"required": []string{"feed_key"},
		}).
		WithCredentialRequirements(map[string]any{
			"api_token": map[string]any{
				"required":    true,
				"description": "Credential broker ref for producer downloads",
			},
		}).
		WithPayloadTemplate(map[string]any{"mode": "full"}).
		WithRedaction(map[string]any{"fields": []string{"credential_refs.api_token"}}).
		WithDispatchScope(ProducerScheduleDispatchTargetQuery).
		WithTimeoutSeconds(900)

	data, err := json.Marshal(contract)
	if err != nil {
		t.Fatal(err)
	}

	payload := string(data)
	for _, required := range []string{
		`"schedule_id":"advisory.refresh"`,
		`"command_type":"plugin.run_action"`,
		`"allow_cron":true`,
		`"cron_expression":"0 */6 * * *"`,
		`"dispatch_scope":"target_query"`,
		`"credential_requirements"`,
		`"settings_schema"`,
		`"payload_template"`,
	} {
		if !strings.Contains(payload, required) {
			t.Fatalf("producer schedule contract missing %s in %s", required, payload)
		}
	}

	for _, provider := range []string{"cisa", "nvd", "vulncheck", "osv"} {
		if strings.Contains(strings.ToLower(payload), provider) {
			t.Fatalf("generic producer schedule leaked provider-specific assumptions: %s", payload)
		}
	}
}
