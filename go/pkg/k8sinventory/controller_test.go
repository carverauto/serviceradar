package k8sinventory

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"
)

func TestController_PublishesOnChangeAndSkipsUnchanged(t *testing.T) {
	t.Parallel()

	cfg := Config{
		ClusterID:            "demo",
		PublishMode:          "none",
		Subject:              "inventory.k8s.public_endpoints",
		EnableGatewayAPI:     true,
		Resync:               time.Hour,
		Debounce:             10 * time.Millisecond,
		PublishTimeout:       time.Second,
		PublishMaxRetries:    1,
		PublishRetryDelay:    time.Millisecond,
		PublishRetryMaxDelay: 5 * time.Millisecond,
	}

	lister := &MemoryLister{
		Services: []ServiceView{{
			Namespace: "ns",
			Name:      "lb",
			Type:      "LoadBalancer",
			Ports:     []ServicePortView{{Port: 443, Protocol: "TCP", TargetPort: 8443}},
			Ingress:   []LoadBalancerIngressView{{IP: "198.51.100.1"}},
		}},
	}
	rec := &RecordingPublisher{}
	ctrl := NewController(cfg, lister, rec, NewMetrics())

	ctx := context.Background()
	if err := ctrl.RebuildOnce(ctx); err != nil {
		t.Fatalf("first rebuild: %v", err)
	}
	if rec.Len() != 1 {
		t.Fatalf("want 1 publish, got %d", rec.Len())
	}
	if !ctrl.Ready() {
		t.Fatal("expected ready after publish")
	}

	// Unchanged content should not republish.
	if err := ctrl.RebuildOnce(ctx); err != nil {
		t.Fatalf("second rebuild: %v", err)
	}
	if rec.Len() != 1 {
		t.Fatalf("want still 1 publish after unchanged rebuild, got %d", rec.Len())
	}
	if ctrl.Metrics().rebuildSkipped.Load() < 1 {
		t.Fatalf("expected rebuild skip counter")
	}

	// Change inventory → publish again.
	lister.Services[0].Ingress[0].IP = "198.51.100.2"
	if err := ctrl.RebuildOnce(ctx); err != nil {
		t.Fatalf("third rebuild: %v", err)
	}
	if rec.Len() != 2 {
		t.Fatalf("want 2 publishes after change, got %d", rec.Len())
	}

	var snap Snapshot
	if err := json.Unmarshal(rec.PayloadAt(1), &snap); err != nil {
		t.Fatal(err)
	}
	if len(snap.Endpoints) != 1 || snap.Endpoints[0].IP != "198.51.100.2" {
		t.Fatalf("snapshot payload: %+v", snap.Endpoints)
	}
	if rec.SubjectAt(0) != cfg.Subject {
		t.Fatalf("subject: %q", rec.SubjectAt(0))
	}
}

func TestController_PublishesNodeSnapshotWhenEnabled(t *testing.T) {
	t.Parallel()

	cfg := Config{
		ClusterID:            "cluster-a",
		PublishMode:          "none",
		Subject:              "inventory.k8s.public_endpoints",
		EnableNodes:          true,
		Resync:               time.Hour,
		Debounce:             10 * time.Millisecond,
		PublishTimeout:       time.Second,
		PublishMaxRetries:    1,
		PublishRetryDelay:    time.Millisecond,
		PublishRetryMaxDelay: 5 * time.Millisecond,
	}
	lister := &MemoryLister{
		Nodes: []NodeView{{
			Name:        "node-worker-1.example.com",
			Ready:       false,
			ReadyReason: "KubeletNotReady",
			InternalIP:  "192.0.2.11",
		}},
	}
	rec := &RecordingPublisher{}
	ctrl := NewController(cfg, lister, rec, NewMetrics())
	if err := ctrl.RebuildOnce(context.Background()); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if rec.Len() != 2 {
		t.Fatalf("want endpoint + node publish, got %d", rec.Len())
	}
	foundNodes := false
	for i := 0; i < rec.Len(); i++ {
		if rec.SubjectAt(i) != defaultNodeSubject {
			continue
		}
		foundNodes = true
		var snap NodeSnapshot
		if err := json.Unmarshal(rec.PayloadAt(i), &snap); err != nil {
			t.Fatal(err)
		}
		if snap.ClusterID != "cluster-a" || len(snap.Nodes) != 1 {
			t.Fatalf("node snapshot: %+v", snap)
		}
		if snap.Nodes[0].Name != "node-worker-1.example.com" || snap.Nodes[0].Ready {
			t.Fatalf("node: %+v", snap.Nodes[0])
		}
	}
	if !foundNodes {
		t.Fatal("missing inventory.k8s.nodes publish")
	}
}

func TestController_RunDebounce(t *testing.T) {
	t.Parallel()

	cfg := Config{
		ClusterID:            "demo",
		Subject:              "inventory.k8s.public_endpoints",
		Resync:               time.Hour,
		Debounce:             50 * time.Millisecond,
		PublishTimeout:       time.Second,
		PublishMaxRetries:    0,
		PublishRetryDelay:    time.Millisecond,
		PublishRetryMaxDelay: time.Millisecond,
		PublishMode:          "none",
	}
	lister := &MemoryLister{
		Services: []ServiceView{{
			Namespace: "ns",
			Name:      "lb",
			Type:      "LoadBalancer",
			Ports:     []ServicePortView{{Port: 80, Protocol: "TCP", TargetPort: 80}},
			Ingress:   []LoadBalancerIngressView{{IP: "203.0.113.1"}},
		}},
	}
	rec := &RecordingPublisher{}
	ctrl := NewController(cfg, lister, rec, NewMetrics())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- ctrl.Run(ctx) }()

	// Wait for initial publish.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if rec.Len() >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if rec.Len() < 1 {
		t.Fatal("initial publish missing")
	}

	// Burst of notifies should coalesce.
	before := rec.Len()
	// Swap the whole slice instead of editing an element: the Controller goroutine is
	// reading the previous one right now.
	lister.SetServices([]ServiceView{{
		Namespace: "ns",
		Name:      "lb",
		Type:      "LoadBalancer",
		Ports:     []ServicePortView{{Port: 8080, Protocol: "TCP", TargetPort: 80}},
		Ingress:   []LoadBalancerIngressView{{IP: "203.0.113.1"}},
	}})
	for i := 0; i < 5; i++ {
		ctrl.Notify()
	}
	time.Sleep(200 * time.Millisecond)
	after := rec.Len()
	if after != before+1 {
		t.Fatalf("debounced publishes: before=%d after=%d want +1", before, after)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("controller did not exit")
	}
}

func TestLoadConfigFromEnv_StdoutMode(t *testing.T) {
	t.Setenv("CLUSTER_ID", "demo")
	t.Setenv("PUBLISH_MODE", publishModeStdout)
	t.Setenv("NATS_HOSTPORT", "")
	cfg, err := LoadConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublishMode != publishModeStdout {
		t.Fatalf("mode: %s", cfg.PublishMode)
	}
	pub, err := NewPublisherFromConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !pub.IsConnected() {
		t.Fatal("stdout publisher should be connected")
	}
}

func TestLoadConfigFromEnv_NATSRequiresURL(t *testing.T) {
	t.Setenv("CLUSTER_ID", "demo")
	t.Setenv("PUBLISH_MODE", "nats")
	t.Setenv("NATS_HOSTPORT", "")
	_, err := LoadConfigFromEnv()
	if err == nil {
		t.Fatal("expected error")
	}
}

// countingLister reports how many rebuilds actually reached the lister.
type countingLister struct {
	*MemoryLister
	calls atomic.Int64
}

func (c *countingLister) ListServices(ctx context.Context, ns string) ([]ServiceView, error) {
	c.calls.Add(1)
	return c.MemoryLister.ListServices(ctx, ns)
}

func TestController_ResyncRebuildsUnderSustainedNotifies(t *testing.T) {
	t.Parallel()

	// Notifies arrive faster than the debounce, so the debounce timer is reset
	// before it can ever expire. Only the resync tick can still produce a
	// rebuild; if it merely re-notifies, endpoint publishing starves.
	cfg := Config{
		ClusterID:            "demo",
		Subject:              "inventory.k8s.public_endpoints",
		Resync:               60 * time.Millisecond,
		Debounce:             time.Hour,
		PublishTimeout:       time.Second,
		PublishMaxRetries:    0,
		PublishRetryDelay:    time.Millisecond,
		PublishRetryMaxDelay: time.Millisecond,
		PublishMode:          "none",
	}
	lister := &countingLister{MemoryLister: &MemoryLister{
		Services: []ServiceView{{
			Namespace: "ns",
			Name:      "lb",
			Type:      "LoadBalancer",
			Ports:     []ServicePortView{{Port: 80, Protocol: "TCP", TargetPort: 80}},
			Ingress:   []LoadBalancerIngressView{{IP: "203.0.113.1"}},
		}},
	}}
	ctrl := NewController(cfg, lister, &RecordingPublisher{}, NewMetrics())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- ctrl.Run(ctx) }()

	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
				ctrl.Notify()
				time.Sleep(time.Millisecond)
			}
		}
	}()

	// One rebuild is the unconditional initial one; anything beyond it can only
	// have come from a resync tick.
	deadline := time.After(2 * time.Second)
	for lister.calls.Load() < 3 {
		select {
		case <-deadline:
			close(stop)
			t.Fatalf("rebuild starved under sustained notifies: only %d rebuilds", lister.calls.Load())
		default:
			time.Sleep(5 * time.Millisecond)
		}
	}
	close(stop)

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run: %v", err)
	}
}
