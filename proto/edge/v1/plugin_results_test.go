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
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestWasmPluginResultBatchV1RoundTrip(t *testing.T) {
	t.Parallel()

	const observedNanos = int64(1_784_000_000_000_000_000)

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
						PayloadJson:  []byte(`{"target":"192.0.2.10"}`),
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
									SiteCode:  "EXAMPLE-01",
									SiteName:  "Example Lab",
									Latitude:  0.0,
									Longitude: 0.0,
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
					Schema:                  "serviceradar.northbound_action_result.v1",
					Status:                  "succeeded",
					SummaryJson:             []byte(`{"updated":1}`),
					ExternalCorrelationId:   "corr-0001",
					ContinuationStateJson:   []byte(`{}`),
					PollMode:                "poll",
					NextPollAt:              "2026-07-14T00:01:00Z",
					NextPollDelaySeconds:    60,
					PollDeadlineAt:          "2026-07-14T00:10:00Z",
					MaxDurationSeconds:      600,
					TargetsJson:             []byte(`[{"device_uid":"sr:00000000-0000-4000-8000-000000000005","status":"succeeded"}]`),
					ErrorClass:              "",
					ErrorMessage:            "",
					MetadataJson:            []byte(`{"ticket":"SYN-1"}`),
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
