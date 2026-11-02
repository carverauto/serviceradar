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

package edgev1_test

import (
	"encoding/json"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestWasmPluginResultBatchV1RoundTrip(t *testing.T) {
	t.Parallel()

	const observedNanos = int64(1_784_000_000_000_000_000)
	eventPayload := fullOCSFEventJSON(t, observedNanos)

	original := &edgev1.WasmPluginResultBatchV1{
		Provenance: &edgev1.PluginResultProvenanceV1{
			AssignmentId:    "asgn-00000000-0000-4000-8000-000000000001",
			PluginId:        "http-synthetic-check",
			PluginPackageId: "pkg-00000000-0000-4000-8000-000000000002",
			PluginVersion:   "1.2.3",
			ContentHash:     "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		Results: []*edgev1.WasmPluginResultItemV1{
			{
				SchemaVersion:      1,
				Status:             edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_OK,
				Summary:            "synthetic HTTP check healthy",
				Details:            "GET https://status.example.com/healthz returned 200",
				Perfdata:           "response_ms=12ms;100;250;0;",
				Labels:             map[string]string{"env": "lab", "target": "status.example.com"},
				ObservedAtUnixNano: observedNanos,
				AlertHint:          false,
				ConditionId:        "cond-http-healthz",
				CheckInstanceId:    "chk-00000000-0000-4000-8000-000000000003",
				MonitoredServiceId: "svc-00000000-0000-4000-8000-000000000004",
				DeviceUid:          "sr:00000000-0000-4000-8000-000000000005",
				ServiceName:        "http-synthetic-check",
				ServiceType:        "plugin",
				RunOverridesAcknowledged: []string{
					"ovr-00000000-0000-4000-8000-000000000009",
				},
				Display: []*edgev1.PluginDisplayInstructionV1{
					{
						Widget:   "stat_card",
						Label:    "Response Time",
						Value:    "12ms",
						Tone:     "ok",
						Layout:   "compact",
						DataJson: []byte(`{"p95_ms":15}`),
					},
				},
				Events: []*edgev1.PluginEventEnvelopeV1{
					{
						Id:           "evt-00000000-0000-4000-8000-000000000007",
						TimeUnixNano: observedNanos,
						ClassUid:     1008,
						CategoryUid:  1,
						TypeUid:      100801,
						ActivityId:   1,
						ActivityName: "Create",
						SeverityId:   1,
						Severity:     "Informational",
						Message:      "probe completed",
						PayloadJson:  eventPayload,
					},
				},
				DeviceDiscovery: []*edgev1.PluginDeviceDiscoveryItemV1{
					{
						Schema:        "serviceradar.device_discovery.v1",
						CollectionId:  "col-00000000-0000-4000-8000-000000000008",
						Source:        "http-synthetic-check",
						ObservedAt:    "2026-07-14T00:00:00Z",
						ReferenceHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
						Devices: []*edgev1.PluginDiscoveredDeviceV1{
							{
								DeviceId:       "dev-192-0-2-10",
								Hostname:       "edge-sensor.example.com",
								Ip:             "192.0.2.10",
								Mac:            "00:00:5e:00:53:0a",
								Serial:         "SYN-0001",
								VendorName:     "Example Corp",
								Model:          "SR-100",
								Type:           "router",
								Role:           "edge",
								Status:         "online",
								HasIsAvailable: true,
								IsAvailable:    true,
								Location: &edgev1.PluginDeviceLocationV1{
									SiteCode: "EXAMPLE-01",
									SiteName: "Example Lab",
								},
								Labels:       map[string]string{"role": "sensor"},
								MetadataJson: []byte(`{"os":"linux"}`),
							},
						},
						MetadataJson: []byte(`{"collector":"synthetic"}`),
					},
				},
				AdvisoryFeeds: []*edgev1.PluginAdvisoryFeedBatchV1{
					{
						SchemaVersion: "serviceradar.advisory_feed.contract.v1",
						ProducerId:    "http-synthetic-check",
						SourceJson:    []byte(`{"provider":"example","feed_key":"example-advisories","enabled":true}`),
						SnapshotJson:  []byte(`{"object_key":"advisories/snapshot-1.json","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","accepted":true}`),
						AdvisoriesJson: [][]byte{
							[]byte(`{"source_object_id":"obj-1","advisory_id":"ADV-2026-0001"}`),
						},
						MetadataJson: []byte(`{"page":1}`),
					},
				},
				StagedArtifact: &edgev1.PluginStagedArtifactV1{
					ObjectKey:   "agent-artifacts/agent-1/asgn-1/opentext-nom/running-config/1/0123456789abcdef0123456789abcdef",
					ContentType: "text/plain",
					Sha256:      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
					SizeBytes:   4096,
					Attributes:  map[string]string{"device": "192.0.2.10"},
				},
				InterfaceConfigChecks: &edgev1.PluginContractPayloadV1{
					Schema:        "serviceradar.interface_config_check_batch.v1",
					SchemaVersion: 1,
					PayloadJson:   []byte(`{"checks":[]}`),
				},
				HypervisorEnrichment: &edgev1.PluginContractPayloadV1{
					Schema:        "serviceradar.hypervisor_enrichment_batch.v1",
					SchemaVersion: 1,
					PayloadJson:   []byte(`{"hosts":[]}`),
				},
				ProxmoxEnrichment: &edgev1.PluginContractPayloadV1{
					Schema:        "serviceradar.proxmox_enrichment.v1",
					SchemaVersion: 1,
					PayloadJson:   []byte(`{"nodes":[]}`),
				},
				WifiMapBatch: &edgev1.PluginContractPayloadV1{
					Schema:        "serviceradar.wifi_map_batch.v1",
					SchemaVersion: 1,
					PayloadJson:   []byte(`{"aps":[]}`),
				},
				ThreatIntelPage: &edgev1.PluginContractPayloadV1{
					Schema:        "serviceradar.threat_intel_indicator_page.v1",
					SchemaVersion: 1,
					PayloadJson:   []byte(`{"indicators":[]}`),
				},
				CameraDescriptors: []*edgev1.PluginContractPayloadV1{
					{
						Schema:        "serviceradar.camera_source_descriptor.v1",
						SchemaVersion: 1,
						PayloadJson:   []byte(`{"camera_id":"cam-1"}`),
					},
				},
				ActionResult: &edgev1.PluginActionResultV1{
					Schema:                "serviceradar.northbound_action_result.v1",
					Status:                "succeeded",
					SummaryJson:           []byte(`{"updated":1}`),
					ExternalCorrelationId: "corr-0001",
					ContinuationStateJson: []byte(`{}`),
					PollMode:              "poll",
					NextPollAt:            "2026-07-14T00:01:00Z",
					NextPollDelaySeconds:  60,
					PollDeadlineAt:        "2026-07-14T00:10:00Z",
					MaxDurationSeconds:    600,
					TargetsJson:           []byte(`[{"device_uid":"sr:00000000-0000-4000-8000-000000000005","status":"succeeded"}]`),
					ErrorClass:            "",
					ErrorMessage:          "",
					MetadataJson:          []byte(`{"ticket":"SYN-1"}`),
					RunOverridesJson:      []byte(`[{"op":"set","id":"ovr-00000000-0000-4000-8000-000000000009","kind":"maintenance","target":"sr:00000000-0000-4000-8000-000000000005","params":{"window":"lab"},"duration_seconds":600}]`),
				},
				ContractPayloads: []*edgev1.PluginContractPayloadV1{
					{
						Schema:        "serviceradar.plugin_display.v1",
						SchemaVersion: 1,
						PayloadJson:   []byte(`{"widgets":[]}`),
					},
				},
			},
		},
	}

	wire, err := proto.Marshal(original)
	if err != nil {
		t.Fatalf("proto.Marshal failed: %v", err)
	}
	if len(wire) == 0 {
		t.Fatal("expected non-empty wire bytes")
	}

	var decoded edgev1.WasmPluginResultBatchV1
	if err := proto.Unmarshal(wire, &decoded); err != nil {
		t.Fatalf("proto.Unmarshal failed: %v", err)
	}
	if !proto.Equal(original, &decoded) {
		t.Fatalf("decoded batch did not match original:\ngot:  %+v\nwant: %+v", &decoded, original)
	}

	var event map[string]any
	if err := json.Unmarshal(decoded.GetResults()[0].GetEvents()[0].GetPayloadJson(), &event); err != nil {
		t.Fatalf("payload_json is not the OCSF event JSON: %v", err)
	}
	device, _ := event["device"].(map[string]any)
	unmapped, _ := event["unmapped"].(map[string]any)
	metadata, _ := event["metadata"].(map[string]any)
	if device["uid"] != "sr:00000000-0000-4000-8000-000000000005" {
		t.Fatalf("payload device.uid = %#v", device["uid"])
	}
	if unmapped["camera_id"] != "cam-1" || unmapped["camera_device_uid"] != device["uid"] {
		t.Fatalf("payload unmapped = %#v", unmapped)
	}
	if metadata["version"] != "1.7.0" || metadata["logged_time"] == "" {
		t.Fatalf("payload metadata = %#v", metadata)
	}
	if event["log_name"] != "events.ocsf.processed" || event["log_provider"] != "serviceradar-plugin" {
		t.Fatalf("payload log identity = log_name %#v log_provider %#v", event["log_name"], event["log_provider"])
	}
	location := decoded.GetResults()[0].GetDeviceDiscovery()[0].GetDevices()[0].GetLocation()
	if location.GetHasLatitude() || location.GetHasLongitude() || location.GetLatitude() != 0 || location.GetLongitude() != 0 {
		t.Fatalf("site-only location claimed coordinates: %+v", location)
	}
	var runOverrides []map[string]any
	if err := json.Unmarshal(decoded.GetResults()[0].GetActionResult().GetRunOverridesJson(), &runOverrides); err != nil {
		t.Fatalf("run_overrides_json: %v", err)
	}
	if len(runOverrides) != 1 ||
		runOverrides[0]["op"] != "set" ||
		runOverrides[0]["id"] != "ovr-00000000-0000-4000-8000-000000000009" ||
		runOverrides[0]["kind"] != "maintenance" ||
		runOverrides[0]["target"] != "sr:00000000-0000-4000-8000-000000000005" ||
		runOverrides[0]["duration_seconds"] != float64(600) {
		t.Fatalf("run_overrides = %#v", runOverrides)
	}
}

func TestPluginDeviceLocationV1CoordinatePresence(t *testing.T) {
	t.Parallel()

	siteOnly := &edgev1.PluginDeviceLocationV1{SiteCode: "EXAMPLE-01", SiteName: "Example Lab"}
	siteWire, err := proto.Marshal(siteOnly)
	if err != nil {
		t.Fatalf("proto.Marshal site-only: %v", err)
	}
	if fields := protoFieldNumbers(t, siteWire); fields[3] || fields[4] || fields[5] || fields[6] {
		t.Fatalf("site-only location wrote coordinate fields: %v", fields)
	}

	nullIsland := &edgev1.PluginDeviceLocationV1{
		SiteCode:     "NULL-ISLAND",
		HasLatitude:  true,
		HasLongitude: true,
	}
	nullWire, err := proto.Marshal(nullIsland)
	if err != nil {
		t.Fatalf("proto.Marshal null island: %v", err)
	}
	nullFields := protoFieldNumbers(t, nullWire)
	if nullFields[3] || nullFields[4] || !nullFields[5] || !nullFields[6] {
		t.Fatalf("present 0,0 coordinates = %v, want flags 5 and 6 only", nullFields)
	}
	var decoded edgev1.PluginDeviceLocationV1
	if err := proto.Unmarshal(nullWire, &decoded); err != nil {
		t.Fatalf("proto.Unmarshal null island: %v", err)
	}
	if !decoded.GetHasLatitude() || !decoded.GetHasLongitude() || decoded.GetLatitude() != 0 || decoded.GetLongitude() != 0 {
		t.Fatalf("present 0,0 round trip = %+v", &decoded)
	}
}

func protoFieldNumbers(t *testing.T, wire []byte) map[protowire.Number]bool {
	t.Helper()
	seen := map[protowire.Number]bool{}
	for len(wire) > 0 {
		num, _, n := protowire.ConsumeField(wire)
		if n < 0 {
			t.Fatalf("protowire.ConsumeField: %v", protowire.ParseError(n))
		}
		seen[num] = true
		wire = wire[n:]
	}
	return seen
}

func fullOCSFEventJSON(t *testing.T, observedNanos int64) []byte {
	t.Helper()
	observed := time.Unix(0, observedNanos).UTC()
	body, err := json.Marshal(struct {
		ID           string         `json:"id"`
		Time         time.Time      `json:"time"`
		ClassUID     int            `json:"class_uid"`
		CategoryUID  int            `json:"category_uid"`
		TypeUID      int            `json:"type_uid"`
		ActivityID   int            `json:"activity_id"`
		ActivityName string         `json:"activity_name,omitempty"`
		SeverityID   int            `json:"severity_id"`
		Severity     string         `json:"severity,omitempty"`
		Message      string         `json:"message,omitempty"`
		Metadata     map[string]any `json:"metadata,omitempty"`
		Device       map[string]any `json:"device,omitempty"`
		LogName      string         `json:"log_name,omitempty"`
		LogProvider  string         `json:"log_provider,omitempty"`
		Unmapped     map[string]any `json:"unmapped,omitempty"`
	}{
		ID:           "evt-00000000-0000-4000-8000-000000000007",
		Time:         observed,
		ClassUID:     1008,
		CategoryUID:  1,
		TypeUID:      100801,
		ActivityID:   1,
		ActivityName: "Create",
		SeverityID:   1,
		Severity:     "Informational",
		Message:      "probe completed",
		Metadata: map[string]any{
			"logged_time": observed.Format(time.RFC3339Nano),
			"product": map[string]any{
				"name":        "plugin",
				"vendor_name": "ServiceRadar",
			},
			"version": "1.7.0",
		},
		Device: map[string]any{
			"name": "cam-1",
			"uid":  "sr:00000000-0000-4000-8000-000000000005",
		},
		LogName:     "events.ocsf.processed",
		LogProvider: "serviceradar-plugin",
		Unmapped: map[string]any{
			"camera_device_uid": "sr:00000000-0000-4000-8000-000000000005",
			"camera_id":         "cam-1",
		},
	})
	if err != nil {
		t.Fatalf("json.Marshal OCSF event: %v", err)
	}
	return body
}

func TestPluginResultsProtoNoOptionalScalarFields(t *testing.T) {
	t.Parallel()

	msgs := edgev1.File_edge_v1_plugin_results_proto.Messages()
	for i := 0; i < msgs.Len(); i++ {
		msg := msgs.Get(i)
		fields := msg.Fields()
		for j := 0; j < fields.Len(); j++ {
			fd := fields.Get(j)
			if fd.Kind() != protoreflect.MessageKind && fd.HasOptionalKeyword() {
				t.Errorf("%s.%s uses proto3 optional on non-message kind %v", msg.FullName(), fd.Name(), fd.Kind())
			}
		}
	}
}
