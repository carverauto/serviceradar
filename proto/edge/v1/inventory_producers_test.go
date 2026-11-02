package edgev1_test

import (
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
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

func TestInventoryProducerProtosNoOptionalScalarFields(t *testing.T) {
	files := []protoreflect.FileDescriptor{
		edgev1.File_edge_v1_workload_identity_proto,
		edgev1.File_edge_v1_endpoint_inventory_proto,
		edgev1.File_edge_v1_bumblebee_proto,
		edgev1.File_edge_v1_k8s_endpoints_proto,
	}

	var walkMessages func(msgs protoreflect.MessageDescriptors)
	walkMessages = func(msgs protoreflect.MessageDescriptors) {
		for i := 0; i < msgs.Len(); i++ {
			msg := msgs.Get(i)
			fields := msg.Fields()
			for j := 0; j < fields.Len(); j++ {
				field := fields.Get(j)
				if field.HasOptionalKeyword() && field.Kind() != protoreflect.MessageKind {
					t.Errorf("%s.%s uses proto3 optional on scalar/enum kind %v", msg.FullName(), field.Name(), field.Kind())
				}
			}
			walkMessages(msg.Messages())
		}
	}

	for _, fd := range files {
		walkMessages(fd.Messages())
	}
}
