package k8sinventory

import (
	"context"
	"encoding/json"
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
	if len(rec.Payloads) != 1 {
		t.Fatalf("want 1 publish, got %d", len(rec.Payloads))
	}
	if !ctrl.Ready() {
		t.Fatal("expected ready after publish")
	}

	// Unchanged content should not republish.
	if err := ctrl.RebuildOnce(ctx); err != nil {
		t.Fatalf("second rebuild: %v", err)
	}
	if len(rec.Payloads) != 1 {
		t.Fatalf("want still 1 publish after unchanged rebuild, got %d", len(rec.Payloads))
	}
	if ctrl.Metrics().rebuildSkipped.Load() < 1 {
		t.Fatalf("expected rebuild skip counter")
	}

	// Change inventory → publish again.
	lister.Services[0].Ingress[0].IP = "198.51.100.2"
	if err := ctrl.RebuildOnce(ctx); err != nil {
		t.Fatalf("third rebuild: %v", err)
	}
	if len(rec.Payloads) != 2 {
		t.Fatalf("want 2 publishes after change, got %d", len(rec.Payloads))
	}

	var snap Snapshot
	if err := json.Unmarshal(rec.Payloads[1], &snap); err != nil {
		t.Fatal(err)
	}
	if len(snap.Endpoints) != 1 || snap.Endpoints[0].IP != "198.51.100.2" {
		t.Fatalf("snapshot payload: %+v", snap.Endpoints)
	}
	if rec.Subjects[0] != cfg.Subject {
		t.Fatalf("subject: %q", rec.Subjects[0])
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
		if len(rec.Payloads) >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(rec.Payloads) < 1 {
		t.Fatal("initial publish missing")
	}

	// Burst of notifies should coalesce.
	before := len(rec.Payloads)
	lister.Services[0].Ports[0].Port = 8080
	for i := 0; i < 5; i++ {
		ctrl.Notify()
	}
	time.Sleep(200 * time.Millisecond)
	after := len(rec.Payloads)
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
	t.Setenv("PUBLISH_MODE", "stdout")
	t.Setenv("NATS_HOSTPORT", "")
	cfg, err := LoadConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublishMode != "stdout" {
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
