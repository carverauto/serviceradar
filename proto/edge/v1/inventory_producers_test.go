package edgev1_test

import (
	"bytes"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func TestWorkloadIdentitySnapshotV1RoundTrip(t *testing.T) {
	want := &edgev1.WorkloadIdentitySnapshotV1{
		ObservedAtUnixNano: 1700000000123456789,
		Enabled:            true,
		Endpoint: &edgev1.WorkloadIdentitySnapshotEndpointV1{
			Type:           "Cri",
			Path:           "/run/containerd/containerd.sock",
			Source:         "ConfigFile",
			ConfigFilePath: "/etc/crictl.yaml",
		},
		Count:             1,
		DegradationReason: "",
		ContextName:       "example-context",
		ClusterId:         "cluster-example-01",
		ClusterName:       "example-cluster",
		Identities: []*edgev1.WorkloadIdentityContainerLookupV1{
			{
				ContainerId: "container-01",
				Identity: &edgev1.WorkloadIdentityRecordV1{
					PodSandboxId:      "sandbox-01",
					PodName:           "api-0",
					PodNamespace:      "default",
					PodUid:            "pod-uid-01",
					ContainerId:       "container-01",
					ContainerName:     "api",
					Image:             "registry.example.com/api:1.2.3",
					ImageRef:          "registry.example.com/api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
					RuntimePid:        4242,
					HasRuntimePid:     true,
					CgroupPath:        "/kubepods.slice/kubepods-burstable.slice/cri-containerd-container-01.scope",
					Labels:            map[string]string{"app": "api"},
					Annotations:       map[string]string{"example.com/role": "edge"},
					RuntimeSource:     "Containerd",
					Confidence:        "High",
					DegradationReason: "",
				},
			},
		},
	}

	raw, err := proto.Marshal(want)
	if err != nil {
		t.Fatalf("Marshal WorkloadIdentitySnapshotV1: %v", err)
	}

	got := &edgev1.WorkloadIdentitySnapshotV1{}
	if err := proto.Unmarshal(raw, got); err != nil {
		t.Fatalf("Unmarshal WorkloadIdentitySnapshotV1: %v", err)
	}

	if !proto.Equal(want, got) {
		t.Fatalf("WorkloadIdentitySnapshotV1 round-trip mismatch:\ngot:  %v\nwant: %v", got, want)
	}
}

func TestEndpointInventoryScanPayloadV1RoundTrip(t *testing.T) {
	want := &edgev1.EndpointInventoryScanPayloadV1{
		SchemaVersion:        "serviceradar.endpoint_inventory.scan.v1",
		AgentId:              "agent-example-01",
		ScanId:               "scan-example-01",
		CollectorVersion:     "0.1.2",
		State:                "scanned",
		CoverageState:        "complete",
		ConfigHash:           "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		LastScanAt:           "2026-11-01T12:00:00Z",
		LastSuccessfulScanAt: "2026-11-01T12:00:00Z",
		Os: &edgev1.EndpointInventoryOSInfoV1{
			Name:       "Debian GNU/Linux",
			Id:         "debian",
			Version:    "12 (bookworm)",
			VersionId:  "12",
			PrettyName: "Debian GNU/Linux 12 (bookworm)",
		},
		EnabledPlugins:  []string{"dpkg", "apk"},
		DetectedPlugins: []string{"dpkg"},
		Diagnostics: []*edgev1.EndpointInventorySourceSummaryV1{
			{
				Name:         "dpkg",
				Type:         "package_source",
				State:        "scanned",
				PackageCount: 2,
				Path:         "/var/lib/dpkg/status",
				Detected:     true,
				HasDetected:  true,
				DurationMs:   15,
			},
			{
				Name:         "apk",
				Type:         "package_source",
				State:        "unavailable",
				PackageCount: 0,
				Reason:       "not_found",
				Path:         "/lib/apk/db/installed",
				Detected:     false,
				HasDetected:  true,
				DurationMs:   1,
			},
		},
		PackageCount:   2,
		PackageSetHash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
		ArtifactHash:   "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
		HashAlgorithm:  "sha256-v1",
		UploadReason:   "changed",
		DurationMs:     16,
		Truncated:      false,
		StandingQuestionResultCounts: []*edgev1.EndpointInventoryStandingQuestionResultCountV1{
			{
				Schema:          "serviceradar.endpoint_inventory.standing_question_result_count.v1",
				QuestionId:      "q-openssl",
				QuestionVersion: "1",
				PredicateHash:   "pred-hash-01",
				Mode:            "count",
				Matched:         true,
				Count:           1,
				PackageSetHash:  "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
				HashAlgorithm:   "sha256-v1",
				EvaluatedAt:     "2026-11-01T12:00:00Z",
				Freshness: &edgev1.EndpointInventoryFreshnessVerdictV1{
					Verdict:               "fresh",
					AgeSeconds:            5,
					StaleThresholdSeconds: 93600,
					LastSuccessfulScanAt:  "2026-11-01T12:00:00Z",
				},
				Labels:   map[string]string{"tier": "core"},
				Metadata: map[string]string{"owner": "secops"},
			},
		},
		Sbom: &edgev1.EndpointInventoryCycloneDXBOMV1{
			BomFormat:    "CycloneDX",
			SpecVersion:  "1.6",
			SerialNumber: "urn:uuid:00000000-0000-4000-8000-000000000001",
			Version:      1,
			Metadata: &edgev1.EndpointInventoryCycloneDXMetadataV1{
				Timestamp: "2026-11-01T12:00:00Z",
				Tools: []*edgev1.EndpointInventoryCycloneDXToolV1{
					{
						Vendor:  "Carver Automation",
						Name:    "serviceradar-endpoint-inventory",
						Version: "0.1.2",
					},
				},
				Component: &edgev1.EndpointInventoryCycloneDXComponentV1{
					Type:    "operating-system",
					Name:    "debian",
					Version: "12",
				},
				Properties: []*edgev1.EndpointInventoryCycloneDXPropertyV1{
					{Name: "serviceradar:agent_id", Value: "agent-example-01"},
				},
			},
			Components: []*edgev1.EndpointInventoryCycloneDXComponentV1{
				{
					Type:    "library",
					Name:    "openssl",
					Version: "3.0.11-1~deb12u2",
					Purl:    "pkg:deb/debian/openssl@3.0.11-1~deb12u2?arch=amd64",
					Cpe:     "cpe:2.3:a:openssl:openssl:3.0.11-1~deb12u2:*:*:*:*:*:*:*",
					Properties: []*edgev1.EndpointInventoryCycloneDXPropertyV1{
						{Name: "serviceradar:package_manager", Value: "dpkg"},
						{Name: "serviceradar:architecture", Value: "amd64"},
					},
				},
			},
		},
		PackageDelta: &edgev1.EndpointInventoryPackageSetDeltaV1{
			Schema:               "serviceradar.endpoint_inventory.package_delta.v1",
			BasePackageSetHash:   "1111111111111111111111111111111111111111111111111111111111111111",
			TargetPackageSetHash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
			HashAlgorithm:        "sha256-v1",
			Added: []*edgev1.EndpointInventoryPackageV1{
				{
					Name:         "curl",
					Version:      "7.88.1-10+deb12u5",
					Architecture: "amd64",
					Manager:      "dpkg",
					Ecosystem:    "debian",
					Purl:         "pkg:deb/debian/curl@7.88.1-10+deb12u5?arch=amd64",
					Cpes:         []string{"cpe:2.3:a:haxx:curl:7.88.1-10+deb12u5:*:*:*:*:*:*:*"},
				},
			},
			Changed: []*edgev1.EndpointInventoryPackageChangeV1{
				{
					Name:            "openssl",
					Version:         "3.0.11-1~deb12u2",
					Architecture:    "amd64",
					Manager:         "dpkg",
					Ecosystem:       "debian",
					Purl:            "pkg:deb/debian/openssl@3.0.11-1~deb12u2?arch=amd64",
					PreviousVersion: "3.0.11-1~deb12u1",
				},
			},
		},
		MetadataJson: []byte(`{"collect_paths":"omitted","collect_file_hashes":"omitted"}`),
	}

	raw, err := proto.Marshal(want)
	if err != nil {
		t.Fatalf("Marshal EndpointInventoryScanPayloadV1: %v", err)
	}

	got := &edgev1.EndpointInventoryScanPayloadV1{}
	if err := proto.Unmarshal(raw, got); err != nil {
		t.Fatalf("Unmarshal EndpointInventoryScanPayloadV1: %v", err)
	}

	if !proto.Equal(want, got) {
		t.Fatalf("EndpointInventoryScanPayloadV1 round-trip mismatch:\ngot:  %v\nwant: %v", got, want)
	}
}

func TestBumblebeeScanPayloadV1RoundTrip(t *testing.T) {
	want := &edgev1.BumblebeeScanPayloadV1{
		SchemaVersion:      "serviceradar.bumblebee.scan.v1",
		AgentId:            "agent-example-01",
		DeviceUid:          "sr:device-example-01",
		RunId:              "run-20261101-01",
		ScannerVersion:     "0.1.0",
		CatalogSnapshotRef: "catalog-sha256-01",
		State:              "scanned",
		CoverageState:      "partial",
		AttemptedRootCount: 2,
		ScannedRootCount:   1,
		SkippedRootCount:   1,
		RootCovered:        true,
		AttemptedRoots:     []string{"/root", "/home/alice"},
		ScannedRoots:       []string{"/root"},
		SkippedRoots: []*edgev1.BumblebeeSkippedRootV1{
			{
				Path:   "/home/alice",
				Reason: "permission_denied",
			},
		},
		LastScanAt:           "2026-11-01T12:00:00Z",
		LastSuccessfulScanAt: "2026-11-01T12:00:00Z",
		Findings: []*edgev1.BumblebeeFindingV1{
			{
				Id:             "rec-01",
				FindingId:      "finding-01",
				CatalogId:      "cat-npm-01",
				Severity:       "high",
				RiskScore:      0,
				HasRiskScore:   true,
				Ecosystem:      "npm",
				PackageName:    "example-pkg",
				PackageVersion: "1.0.0",
				EvidenceJson:   []byte(`{"manifest":"package-lock.json"}`),
				Confidence:     "high",
				MetadataJson:   []byte(`{"scope":"root"}`),
			},
		},
		MetadataJson: []byte(`{"catalog_path":"/var/lib/serviceradar/bumblebee/catalog.json","scan_timeout":"2m"}`),
	}

	raw, err := proto.Marshal(want)
	if err != nil {
		t.Fatalf("Marshal BumblebeeScanPayloadV1: %v", err)
	}

	got := &edgev1.BumblebeeScanPayloadV1{}
	if err := proto.Unmarshal(raw, got); err != nil {
		t.Fatalf("Unmarshal BumblebeeScanPayloadV1: %v", err)
	}

	if !proto.Equal(want, got) {
		t.Fatalf("BumblebeeScanPayloadV1 round-trip mismatch:\ngot:  %v\nwant: %v", got, want)
	}
}

func TestK8sPublicEndpointsSnapshotV1RoundTrip(t *testing.T) {
	want := &edgev1.K8SPublicEndpointsSnapshotV1{
		SchemaVersion: "serviceradar.k8s_public_endpoints.v1",
		AgentId:       "agent-example-01",
		ClusterId:     "cluster-example-01",
		GeneratedAt:   "2026-11-01T12:00:00Z",
		ContentHash:   "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		Endpoints: []*edgev1.K8SPublicEndpointV1{
			{
				ClusterId:             "cluster-example-01",
				Ip:                    "198.51.100.10",
				Hostname:              " ingress.example.com",
				Port:                  443,
				Protocol:              "TCP",
				ExposureClass:         "LoadBalancer",
				ExternalTrafficPolicy: "Local",
				MetallbPool:           "public-pool",
				LoadBalancerIpMode:    "VIP",
				Namespace:             "default",
				ServiceName:           "ingress-gateway",
				ServiceUid:            "svc-uid-01",
				GatewayName:           "main-gateway",
				GatewayClass:          "envoy",
				ListenerName:          "https",
				RouteKind:             "HTTPRoute",
				RouteName:             "web-route",
				BackendRefs: []*edgev1.K8SBackendRefV1{
					{
						Group:     "",
						Kind:      "Service",
						Namespace: "default",
						Name:      "web-svc",
						Port:      8080,
						Weight:    100,
					},
				},
				EndpointTargets: []*edgev1.K8SEndpointTargetV1{
					{
						Ip:           "192.0.2.40",
						Port:         8080,
						Protocol:     "TCP",
						PodNamespace: "default",
						PodName:      "web-0",
						NodeName:     "node-01",
						Ready:        true,
					},
				},
				ServiceTargetPort: 8443,
				ServiceTargetName: "https",
				Annotations:       map[string]string{"metallb.universe.tf/address-pool": "public-pool"},
				ObservedAt:        "2026-11-01T12:00:00Z",
			},
		},
		CorrelationHints: []*edgev1.K8SCorrelationHintV1{
			{
				PublicIp:      "198.51.100.10",
				PublicPort:    443,
				Protocol:      "TCP",
				BackendIp:     "192.0.2.40",
				BackendPort:   8443,
				PodNamespace:  "default",
				PodName:       "web-0",
				NodeName:      "node-01",
				Namespace:     "default",
				ServiceName:   "ingress-gateway",
				GatewayName:   "main-gateway",
				RouteKind:     "HTTPRoute",
				RouteName:     "web-route",
				ExposureClass: "LoadBalancer",
			},
		},
	}

	raw, err := proto.Marshal(want)
	if err != nil {
		t.Fatalf("Marshal K8SPublicEndpointsSnapshotV1: %v", err)
	}

	got := &edgev1.K8SPublicEndpointsSnapshotV1{}
	if err := proto.Unmarshal(raw, got); err != nil {
		t.Fatalf("Unmarshal K8SPublicEndpointsSnapshotV1: %v", err)
	}

	if !proto.Equal(want, got) {
		t.Fatalf("K8SPublicEndpointsSnapshotV1 round-trip mismatch:\ngot:  %v\nwant: %v", got, want)
	}
}

// Wire bytes below are the protobuf encoding spec, not a dump of this generator.
// A bool or numeric zero is omitted. An explicit presence companion (has_*) is a
// separate varint field, so dropping it makes "explicit false/zero" identical to unset.
func TestEndpointInventoryExplicitFalseDetectedDiffersOnWire(t *testing.T) {
	// field 1, string "trivy": tag (1<<3)|2 = 0x0a, length 5.
	// field 10, has_detected=true: tag (10<<3)|0 = 0x50, varint 1.
	// detected=false is omitted. Emitting it, or dropping has_detected, fails the compare.
	const name = "trivy"
	unset := &edgev1.EndpointInventorySourceSummaryV1{Name: name}
	explicit := &edgev1.EndpointInventorySourceSummaryV1{Name: name, HasDetected: true}

	wantUnset := []byte{0x0a, 0x05, 't', 'r', 'i', 'v', 'y'}
	wantExplicit := []byte{0x0a, 0x05, 't', 'r', 'i', 'v', 'y', 0x50, 0x01}
	assertWire(t, "unset detected", unset, wantUnset)
	assertWire(t, "explicit false detected", explicit, wantExplicit)
	if bytes.Equal(wantUnset, wantExplicit) {
		t.Fatal("oracle bytes are not distinct")
	}

	got := &edgev1.EndpointInventorySourceSummaryV1{}
	if err := proto.Unmarshal(wantExplicit, got); err != nil {
		t.Fatalf("Unmarshal explicit false detected: %v", err)
	}
	if got.GetName() != name || got.GetDetected() || !got.GetHasDetected() {
		t.Fatalf("explicit false detected decoded as name=%q detected=%v has_detected=%v", got.GetName(), got.GetDetected(), got.GetHasDetected())
	}
}

func TestBumblebeeExplicitZeroRiskScoreDiffersOnWire(t *testing.T) {
	// field 6, has_risk_score=true: tag (6<<3)|0 = 0x30, varint 1.
	// risk_score=0 is omitted. An encoder that skips the presence bit yields an empty message.
	unset := &edgev1.BumblebeeFindingV1{}
	explicit := &edgev1.BumblebeeFindingV1{HasRiskScore: true}

	assertWire(t, "unset risk score", unset, []byte{})
	assertWire(t, "explicit zero risk score", explicit, []byte{0x30, 0x01})

	got := &edgev1.BumblebeeFindingV1{}
	if err := proto.Unmarshal([]byte{0x30, 0x01}, got); err != nil {
		t.Fatalf("Unmarshal explicit zero risk score: %v", err)
	}
	if got.GetRiskScore() != 0 || !got.GetHasRiskScore() {
		t.Fatalf("explicit zero risk score decoded as risk_score=%d has_risk_score=%v", got.GetRiskScore(), got.GetHasRiskScore())
	}
}

func TestWorkloadIdentityExplicitZeroRuntimePidDiffersOnWire(t *testing.T) {
	// field 10, has_runtime_pid=true: tag (10<<3)|0 = 0x50, varint 1.
	unset := &edgev1.WorkloadIdentityRecordV1{}
	explicit := &edgev1.WorkloadIdentityRecordV1{HasRuntimePid: true}

	assertWire(t, "unset runtime pid", unset, []byte{})
	assertWire(t, "explicit zero runtime pid", explicit, []byte{0x50, 0x01})

	// Nested under snapshot.identities (field 5) -> lookup.identity (field 2).
	// lookup payload is field 2, length-delimited: tag 0x12, len 2, then 50 01.
	// snapshot payload is field 5, length-delimited: tag 0x2a, len 4, then that lookup.
	nested := []byte{0x2a, 0x04, 0x12, 0x02, 0x50, 0x01}
	snapshot := &edgev1.WorkloadIdentitySnapshotV1{
		Identities: []*edgev1.WorkloadIdentityContainerLookupV1{{
			Identity: explicit,
		}},
	}
	assertWire(t, "nested explicit zero runtime pid", snapshot, nested)

	got := &edgev1.WorkloadIdentitySnapshotV1{}
	if err := proto.Unmarshal(nested, got); err != nil {
		t.Fatalf("Unmarshal nested runtime pid: %v", err)
	}
	if len(got.GetIdentities()) != 1 || got.GetIdentities()[0].GetIdentity().GetRuntimePid() != 0 || !got.GetIdentities()[0].GetIdentity().GetHasRuntimePid() {
		t.Fatalf("nested explicit zero runtime pid decoded as %+v", got)
	}
}

func assertWire(t *testing.T, label string, msg proto.Message, want []byte) {
	t.Helper()
	got, err := proto.Marshal(msg)
	if err != nil {
		t.Fatalf("Marshal %s: %v", label, err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("%s wire bytes = %x, want %x", label, got, want)
	}
}
