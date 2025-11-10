package config

import (
	"context"
	"testing"
	"time"
)

type fakeKVClient struct {
	value []byte
}

func (f *fakeKVClient) Get(_ context.Context, _ string) ([]byte, bool, error) {
	if len(f.value) == 0 {
		return nil, false, nil
	}
	return f.value, true, nil
}

func (f *fakeKVClient) Put(_ context.Context, _ string, value []byte, _ time.Duration) error {
	f.value = value
	return nil
}

func (f *fakeKVClient) Delete(context.Context, string) error                 { return nil }
func (f *fakeKVClient) Watch(context.Context, string) (<-chan []byte, error) { return nil, nil }
func (f *fakeKVClient) Close() error                                         { return nil }

func TestNeedsPlaceholderRepair(t *testing.T) {
	desc := ServiceDescriptor{
		Name:           "agent",
		KVKey:          "config/agents/default.json",
		CriticalFields: []string{"kv_address"},
	}

	raw := []byte(`{"kv_address":"127.0.0.1:50057","listen_addr":":50051"}`)
	if !needsPlaceholderRepair(desc, raw) {
		t.Fatalf("expected placeholder to be detected")
	}

	raw = []byte(`{"kv_address":"serviceradar-datasvc:50057"}`)
	if needsPlaceholderRepair(desc, raw) {
		t.Fatalf("did not expect placeholder detection for real hostname")
	}

	desc = ServiceDescriptor{
		Name:           "core",
		KVKey:          "config/core.json",
		CriticalFields: []string{"auth.jwt_public_key_pem"},
	}
	raw = []byte(`{"auth":{}}`)
	if !needsPlaceholderRepair(desc, raw) {
		t.Fatalf("expected missing field to trigger repair")
	}
}

func TestRepairConfigPlaceholders(t *testing.T) {
	manager := &KVManager{
		client: &fakeKVClient{
			value: []byte(`{"kv_address":"127.0.0.1:50057","agent_id":"default-agent"}`),
		},
	}

	desc := ServiceDescriptor{
		Name:           "agent",
		KVKey:          "config/agents/default-agent.json",
		CriticalFields: []string{"kv_address"},
	}

	cfg := struct {
		KVAddress string `json:"kv_address"`
	}{
		KVAddress: "serviceradar-datasvc:50057",
	}

	err := manager.RepairConfigPlaceholders(context.Background(), desc, "", &cfg)
	if err != nil {
		t.Fatalf("repair failed: %v", err)
	}

	if string(manager.client.(*fakeKVClient).value) != `{"kv_address":"serviceradar-datasvc:50057"}` {
		t.Fatalf("expected kv config to be rewritten, got %s", manager.client.(*fakeKVClient).value)
	}
}
