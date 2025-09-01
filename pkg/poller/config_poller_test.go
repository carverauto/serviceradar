package poller

import (
    "context"
    "testing"
    "time"

    "go.uber.org/mock/gomock"

    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
)

func TestConfigPoller_executeGetConfig_SourceAndKvFallback(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()

    mockClient := proto.NewMockAgentServiceClient(ctrl)

    cfgBytes := []byte(`{"hello":"world"}`)

    // Case 1: Response has empty KvStoreId -> fallback to poller.config.KVAddress
    mockClient.EXPECT().GetConfig(gomock.Any(), gomock.Any()).Return(&proto.ConfigResponse{
        Config:    cfgBytes,
        AgentId:   "agent-1",
        KvStoreId: "",
    }, nil)

    cp := &ConfigPoller{
        client:    mockClient,
        check:     Check{Name: "sync", Type: "grpc"},
        pollerID:  "poller-1",
        agentName: "agent-1",
        interval:  time.Second,
        poller:    &Poller{config: Config{KVAddress: "kv-fallback"}},
    }

    status := cp.executeGetConfig(context.Background())
    if status == nil {
        t.Fatalf("expected status, got nil")
    }
    if got, want := status.Source, "config"; got != want {
        t.Fatalf("status.Source = %q, want %q", got, want)
    }
    if got, want := status.ServiceName, "sync"; got != want {
        t.Fatalf("status.ServiceName = %q, want %q", got, want)
    }
    if got, want := status.ServiceType, "grpc"; got != want {
        t.Fatalf("status.ServiceType = %q, want %q", got, want)
    }
    if string(status.Message) != string(cfgBytes) {
        t.Fatalf("status.Message mismatch: got %q want %q", string(status.Message), string(cfgBytes))
    }
    if got, want := status.KvStoreId, "kv-fallback"; got != want {
        t.Fatalf("status.KvStoreId = %q, want %q (fallback)", got, want)
    }

    // Case 2: Response provides KvStoreId -> use it
    mockClient2 := proto.NewMockAgentServiceClient(ctrl)
    mockClient2.EXPECT().GetConfig(gomock.Any(), gomock.Any()).Return(&proto.ConfigResponse{
        Config:    cfgBytes,
        AgentId:   "agent-1",
        KvStoreId: "kv-123",
    }, nil)

    cp2 := &ConfigPoller{
        client:    mockClient2,
        check:     Check{Name: "sync", Type: "grpc"},
        pollerID:  "poller-1",
        agentName: "agent-1",
        interval:  time.Second,
        poller:    &Poller{config: Config{KVAddress: "kv-fallback"}},
    }
    status2 := cp2.executeGetConfig(context.Background())
    if status2 == nil {
        t.Fatalf("expected status2, got nil")
    }
    if got, want := status2.KvStoreId, "kv-123"; got != want {
        t.Fatalf("status2.KvStoreId = %q, want %q", got, want)
    }
}

func TestBuildAndExecuteConfigPollers(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()

    mockClient := proto.NewMockAgentServiceClient(ctrl)
    cfgBytes := []byte(`{"a":1}`)

    mockClient.EXPECT().GetConfig(gomock.Any(), gomock.Any()).Return(&proto.ConfigResponse{
        Config:  cfgBytes,
        AgentId: "agent-x",
    }, nil)

    // Prepare AgentConfig with one check using config_interval
    dur := models.Duration(1 * time.Second)
    ac := &AgentConfig{
        Checks: []Check{{
            Type:           "grpc",
            Name:           "sync",
            ConfigInterval: &dur,
        }},
    }

    p := &Poller{config: Config{PollerID: "poller-x", KVAddress: "kv-addr"}}

    list := BuildConfigPollers("agent-x", ac, mockClient, p)
    if len(list) != 1 {
        t.Fatalf("expected 1 config poller, got %d", len(list))
    }

    statuses := ExecuteConfigPollers(context.Background(), list)
    if len(statuses) != 1 {
        t.Fatalf("expected 1 status from ExecuteConfigPollers, got %d", len(statuses))
    }
    st := statuses[0]
    if st == nil || st.Source != "config" {
        t.Fatalf("expected Source=config status, got %#v", st)
    }
    if string(st.Message) != string(cfgBytes) {
        t.Fatalf("status.Message mismatch: got %q want %q", string(st.Message), string(cfgBytes))
    }
}

