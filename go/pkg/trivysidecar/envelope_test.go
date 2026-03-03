package trivysidecar

import (
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
}
