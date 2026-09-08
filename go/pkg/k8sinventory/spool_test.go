package k8sinventory

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSpoolPublisherAtomicWriteAndRead(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	pub, err := NewSpoolPublisher(dir)
	if err != nil {
		t.Fatalf("NewSpoolPublisher: %v", err)
	}
	payload := []byte(`{"cluster_id":"demo","endpoints":[]}`)
	if err := pub.Publish(context.Background(), "inventory.k8s.public_endpoints", payload); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	got, err := ReadLatestSpool(dir)
	if err != nil {
		t.Fatalf("ReadLatestSpool: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("payload mismatch: got %s want %s", got, payload)
	}
	// Second publish replaces
	payload2 := []byte(`{"cluster_id":"demo","endpoints":[{"ip":"1.2.3.4"}]}`)
	if err := pub.Publish(context.Background(), "x", payload2); err != nil {
		t.Fatalf("Publish 2: %v", err)
	}
	got, err = os.ReadFile(filepath.Join(dir, LatestFileName))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(payload2) {
		t.Fatalf("second payload mismatch")
	}
	if !pub.IsConnected() {
		t.Fatal("expected connected")
	}
	pub.Close()
	if pub.IsConnected() {
		t.Fatal("expected closed")
	}
	if err := pub.Publish(context.Background(), "x", payload); err == nil {
		t.Fatal("expected error after close")
	}
}

func TestSpoolPublisherRejectsOversized(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	pub, err := NewSpoolPublisher(dir)
	if err != nil {
		t.Fatal(err)
	}
	huge := make([]byte, MaxSpoolPayloadBytes+1)
	if err := pub.Publish(context.Background(), "x", huge); err == nil {
		t.Fatal("expected size error")
	}
}

func TestConfigAcceptsAgentSpool(t *testing.T) {
	t.Setenv("CLUSTER_ID", "demo")
	t.Setenv("PUBLISH_MODE", publishModeAgentSpool)
	t.Setenv("K8S_INVENTORY_SPOOL_DIR", t.TempDir())
	t.Setenv("NATS_HOSTPORT", "")
	cfg, err := LoadConfigFromEnv()
	if err != nil {
		t.Fatalf("LoadConfigFromEnv: %v", err)
	}
	if cfg.PublishMode != publishModeAgentSpool {
		t.Fatalf("mode=%s", cfg.PublishMode)
	}
	pub, err := NewPublisherFromConfig(cfg)
	if err != nil {
		t.Fatalf("NewPublisherFromConfig: %v", err)
	}
	defer pub.Close()
	if err := pub.Publish(context.Background(), cfg.Subject, []byte(`{}`)); err != nil {
		t.Fatalf("Publish: %v", err)
	}
}

func TestConfigRejectsNodesWithAgentSpool(t *testing.T) {
	t.Setenv("CLUSTER_ID", "demo")
	t.Setenv("PUBLISH_MODE", publishModeAgentSpool)
	t.Setenv("K8S_INVENTORY_SPOOL_DIR", t.TempDir())
	t.Setenv("NATS_HOSTPORT", "")
	t.Setenv("K8S_INVENTORY_NODES", "true")

	if _, err := LoadConfigFromEnv(); !errors.Is(err, errNodesUnsupportedSpool) {
		t.Fatalf("want errNodesUnsupportedSpool, got %v", err)
	}
}

func TestNodeWatchingIsOptIn(t *testing.T) {
	t.Setenv("CLUSTER_ID", "demo")
	t.Setenv("PUBLISH_MODE", publishModeStdout)
	t.Setenv("NATS_HOSTPORT", "")

	cfg, err := LoadConfigFromEnv()
	if err != nil {
		t.Fatalf("LoadConfigFromEnv: %v", err)
	}
	if cfg.EnableNodes {
		t.Fatal("EnableNodes must default false so a manifest without Nodes RBAC does not block cache sync")
	}
}
