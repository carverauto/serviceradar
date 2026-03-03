package trivysidecar

import (
	"context"
	"errors"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

var errPublishFailed = errors.New("publish failed")

type fakePublisher struct {
	calls int

	failFirst int
}

func (f *fakePublisher) Publish(_ context.Context, _ string, _ []byte) error {
	f.calls++
	if f.calls <= f.failFirst {
		return errPublishFailed
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
