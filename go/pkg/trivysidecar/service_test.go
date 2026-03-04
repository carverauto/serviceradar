package trivysidecar

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

var errPublishFailed = errors.New("publish failed")

type fakePublisher struct {
	calls int

	failFirst int
	payloads  [][]byte
}

func (f *fakePublisher) Publish(_ context.Context, _ string, payload []byte) error {
	f.calls++
	if f.calls <= f.failFirst {
		return errPublishFailed
	}

	if len(payload) > 0 {
		clone := make([]byte, len(payload))
		copy(clone, payload)
		f.payloads = append(f.payloads, clone)
	}

	return nil
}

func (f *fakePublisher) Close() {}

func (f *fakePublisher) IsConnected() bool { return true }

func TestProcessReportDeduplicatesByRevision(t *testing.T) {
	t.Parallel()

	pub := &fakePublisher{}
	cfg := Config{
		ClusterID:            "cluster-a",
		NATSSubjectPrefix:    "trivy.report",
		PublishTimeout:       time.Second,
		PublishMaxRetries:    0,
		PublishRetryDelay:    10 * time.Millisecond,
		PublishRetryMaxDelay: 20 * time.Millisecond,
	}

	svc := NewService(cfg, nil, nil, pub, NewMetrics())
	svc.clock = func() time.Time { return time.Date(2026, 3, 3, 10, 0, 0, 0, time.UTC) }

	kind := ReportKind{Kind: "VulnerabilityReport", Resource: "vulnerabilityreports", SubjectSuffix: "vulnerability", Namespaced: true}
	obj := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "aquasecurity.github.io/v1alpha1", "kind": "VulnerabilityReport"}}
	obj.SetName("report-a")
	obj.SetNamespace("demo")
	obj.SetUID(types.UID("uid-a"))
	obj.SetResourceVersion("42")

	if err := svc.processReport(context.Background(), kind, obj.DeepCopy()); err != nil {
		t.Fatalf("processReport first call failed: %v", err)
	}

	if err := svc.processReport(context.Background(), kind, obj.DeepCopy()); err != nil {
		t.Fatalf("processReport duplicate call failed: %v", err)
	}

	obj.SetResourceVersion("43")
	if err := svc.processReport(context.Background(), kind, obj.DeepCopy()); err != nil {
		t.Fatalf("processReport updated revision failed: %v", err)
	}

	if pub.calls != 2 {
		t.Fatalf("expected 2 publish calls, got %d", pub.calls)
	}

	if got := svc.metrics.deduplicatedTotal.Load(); got != 1 {
		t.Fatalf("expected deduplicated_total=1, got %d", got)
	}
}

func TestPublishWithRetry(t *testing.T) {
	t.Parallel()

	pub := &fakePublisher{failFirst: 2}
	cfg := Config{
		ClusterID:            "cluster-a",
		NATSSubjectPrefix:    "trivy.report",
		PublishTimeout:       100 * time.Millisecond,
		PublishMaxRetries:    3,
		PublishRetryDelay:    5 * time.Millisecond,
		PublishRetryMaxDelay: 10 * time.Millisecond,
	}

	svc := NewService(cfg, nil, nil, pub, NewMetrics())
	err := svc.publishWithRetry(context.Background(), "VulnerabilityReport", "trivy.report.vulnerability", []byte("{}"))
	if err != nil {
		t.Fatalf("publishWithRetry failed: %v", err)
	}

	if pub.calls != 3 {
		t.Fatalf("expected 3 publish attempts, got %d", pub.calls)
	}
}

func TestProcessReportAddsPodIdentityToCorrelation(t *testing.T) {
	t.Parallel()

	pod := &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": "v1",
			"kind":       "Pod",
			"metadata": map[string]any{
				"name":      "target-pod",
				"namespace": "demo",
				"uid":       "pod-uid-1",
			},
			"spec": map[string]any{
				"nodeName": "worker-1",
			},
			"status": map[string]any{
				"podIP":  "10.42.0.10",
				"hostIP": "192.168.1.12",
			},
		},
	}

	scheme := runtime.NewScheme()
	dynamicClient := dynamicfake.NewSimpleDynamicClient(scheme, pod)

	pub := &fakePublisher{}
	cfg := Config{
		ClusterID:            "cluster-a",
		NATSSubjectPrefix:    "trivy.report",
		PublishTimeout:       time.Second,
		PublishMaxRetries:    0,
		PublishRetryDelay:    10 * time.Millisecond,
		PublishRetryMaxDelay: 20 * time.Millisecond,
	}

	svc := NewService(cfg, nil, dynamicClient, pub, NewMetrics())
	kind := ReportKind{Kind: "VulnerabilityReport", Resource: "vulnerabilityreports", SubjectSuffix: "vulnerability", Namespaced: true}

	report := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "aquasecurity.github.io/v1alpha1",
		"kind":       "VulnerabilityReport",
		"metadata": map[string]any{
			"name":            "report-1",
			"namespace":       "demo",
			"uid":             "report-uid-1",
			"resourceVersion": "21",
			"labels": map[string]any{
				"trivy-operator.resource.kind":      "Pod",
				"trivy-operator.resource.name":      "target-pod",
				"trivy-operator.resource.namespace": "demo",
			},
		},
	}}

	if err := svc.processReport(context.Background(), kind, report); err != nil {
		t.Fatalf("processReport failed: %v", err)
	}

	if len(pub.payloads) != 1 {
		t.Fatalf("expected one published payload, got %d", len(pub.payloads))
	}

	var envelope Envelope
	if err := json.Unmarshal(pub.payloads[0], &envelope); err != nil {
		t.Fatalf("unmarshal envelope failed: %v", err)
	}

	if envelope.Correlation == nil {
		t.Fatalf("expected envelope correlation")
	}

	if envelope.Correlation.PodIP != "10.42.0.10" {
		t.Fatalf("expected pod IP to be resolved, got %q", envelope.Correlation.PodIP)
	}

	if envelope.Correlation.NodeName != "worker-1" {
		t.Fatalf("expected nodeName=worker-1, got %q", envelope.Correlation.NodeName)
	}

	if envelope.Correlation.PodUID != "pod-uid-1" {
		t.Fatalf("expected pod UID to be resolved, got %q", envelope.Correlation.PodUID)
	}
}
