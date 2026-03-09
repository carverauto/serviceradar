package trivysidecar

import (
	"encoding/json"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

func TestBuildEventIDDeterministic(t *testing.T) {
	t.Parallel()

	one := BuildEventID("cluster-a", "VulnerabilityReport", "demo", "report-1", "25")
	two := BuildEventID("cluster-a", "VulnerabilityReport", "demo", "report-1", "25")
	three := BuildEventID("cluster-a", "VulnerabilityReport", "demo", "report-1", "26")

	if one != two {
		t.Fatalf("expected deterministic event_id, got %q and %q", one, two)
	}

	if one == three {
		t.Fatalf("expected different event_id for a different resourceVersion")
	}
}

func TestBuildEnvelopeIncludesOwnerAndSummary(t *testing.T) {
	t.Parallel()

	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "aquasecurity.github.io/v1alpha1",
		"kind":       "VulnerabilityReport",
		"report": map[string]any{
			"summary": map[string]any{
				"criticalCount": int64(1),
				"highCount":     int64(2),
			},
		},
	}}

	obj.SetName("nginx-vuln")
	obj.SetNamespace("demo")
	obj.SetLabels(map[string]string{
		"trivy-operator.resource.kind":      "Pod",
		"trivy-operator.resource.name":      "nginx-pod-123",
		"trivy-operator.resource.namespace": "demo",
		"trivy-operator.container.name":     "nginx",
	})
	obj.SetUID(types.UID("uid-1"))
	obj.SetResourceVersion("17")
	obj.SetOwnerReferences([]metav1.OwnerReference{{Kind: "ReplicaSet", Name: "nginx-rs", UID: "owner-uid"}})

	envelope, err := BuildEnvelope(
		"cluster-a",
		ReportKind{Kind: "VulnerabilityReport", Resource: "vulnerabilityreports", SubjectSuffix: "vulnerability", Namespaced: true},
		obj,
		time.Date(2026, 3, 3, 9, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatalf("BuildEnvelope failed: %v", err)
	}

	if envelope.OwnerRef == nil || envelope.OwnerRef.Name != "nginx-rs" {
		t.Fatalf("expected owner reference to be captured")
	}

	if envelope.Summary == nil {
		t.Fatalf("expected summary to be extracted")
	}

	if envelope.Summary["criticalCount"] != int64(1) {
		t.Fatalf("expected criticalCount=1, got %#v", envelope.Summary["criticalCount"])
	}

	if envelope.Correlation == nil {
		t.Fatalf("expected correlation to be captured")
	}

	if envelope.Correlation.PodName != "nginx-pod-123" {
		t.Fatalf("expected correlation pod_name=nginx-pod-123, got %q", envelope.Correlation.PodName)
	}

	if envelope.Correlation.ContainerName != "nginx" {
		t.Fatalf("expected correlation container_name=nginx, got %q", envelope.Correlation.ContainerName)
	}
}

func TestBuildEnvelopeCompactsOversizedReportPayload(t *testing.T) {
	t.Parallel()

	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "aquasecurity.github.io/v1alpha1",
		"kind":       "VulnerabilityReport",
		"metadata": map[string]any{
			"creationTimestamp": "2026-03-08T19:00:00Z",
			"labels": map[string]any{
				"trivy-operator.resource.kind":      "Pod",
				"trivy-operator.resource.name":      "runner",
				"trivy-operator.resource.namespace": "arc-systems",
			},
			"managedFields": []any{"drop-me"},
		},
		"report": map[string]any{
			"summary": map[string]any{
				"criticalCount": int64(1),
				"highCount":     int64(2),
			},
			"artifact": map[string]any{
				"repository": "ghcr.io/example/runner",
				"tag":        "latest",
				"digest":     "sha256:drop-me",
			},
			"scanner": map[string]any{
				"name":    "Trivy",
				"version": "0.61.0",
				"vendor":  "drop-me",
			},
			"updateTimestamp": "2026-03-08T19:01:00Z",
			"vulnerabilities": []any{
				map[string]any{
					"vulnerabilityID":  "CVE-2026-0001",
					"title":            "openssl issue",
					"severity":         "HIGH",
					"pkgName":          "openssl",
					"installedVersion": "1.1.1",
					"fixedVersion":     "1.1.2",
					"description":      "important detail",
					"links":            []any{"https://example.com/advisory"},
					"primaryLink":      "https://example.com/primary",
					"cvss":             map[string]any{"nvd": map[string]any{"score": 9.8}},
					"packagePURL":      "pkg:deb/openssl@1.1.1",
				},
			},
		},
	}}

	obj.SetName("runner-vuln")
	obj.SetNamespace("arc-systems")
	obj.SetUID(types.UID("uid-compact"))
	obj.SetResourceVersion("88")

	envelope, err := BuildEnvelope(
		"cluster-a",
		ReportKind{Kind: "VulnerabilityReport", Resource: "vulnerabilityreports", SubjectSuffix: "vulnerability", Namespaced: true},
		obj,
		time.Date(2026, 3, 8, 19, 2, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatalf("BuildEnvelope failed: %v", err)
	}

	reportMetadata := envelope.Report["metadata"].(map[string]any)
	if _, exists := reportMetadata["managedFields"]; exists {
		t.Fatalf("expected managedFields to be removed from compact payload")
	}

	reportPayload := envelope.Report["report"].(map[string]any)
	artifact := reportPayload["artifact"].(map[string]any)
	if _, exists := artifact["digest"]; exists {
		t.Fatalf("expected unused artifact fields to be removed")
	}

	vulnerability := reportPayload["vulnerabilities"].([]map[string]any)[0]
	if _, exists := vulnerability["cvss"]; exists {
		t.Fatalf("expected unused vulnerability fields to be removed")
	}

	references := vulnerability["references"].([]string)
	if len(references) != 2 {
		t.Fatalf("expected merged reference links, got %#v", references)
	}

	payloadBytes, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal envelope failed: %v", err)
	}

	if len(payloadBytes) >= 1024*1024 {
		t.Fatalf("expected compact envelope to stay under 1 MB, got %d bytes", len(payloadBytes))
	}
}
