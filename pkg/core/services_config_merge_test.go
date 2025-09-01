package core

import (
    "context"
    "testing"
    "time"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/pkg/core/api"
    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/proto"
    "go.opentelemetry.io/otel"
)

func TestCreateServiceRecords_ConfigSourceMergesJSON(t *testing.T) {
    s := &Server{logger: logger.NewTestLogger(), tracer: otel.Tracer("test")}
    now := time.Now()

    // apiService holds the message bytes (details payload)
    msg := []byte(`{"alpha": 123}`)
    apiSvc := &api.ServiceStatus{Name: "sync", Type: "grpc", Message: msg}

    // proto service with Source="config" - the Message field here is what gets merged
    ps := &proto.ServiceStatus{ServiceName: "sync", ServiceType: "grpc", AgentId: "agent-1", PollerId: "poller-1", Source: "config", Message: msg}

    _, rec := s.createServiceRecords(context.Background(), ps, apiSvc, "poller-1", "default", "127.0.0.1", now)
    require.NotNil(t, rec)
    require.NotNil(t, rec.Config)

    // rec.Config should contain kv_* defaults and merged alpha
    // kv_enabled/kv_configured default to false when KvStoreId empty
    if rec.Config["kv_enabled"] != "false" || rec.Config["kv_configured"] != "false" {
        t.Fatalf("expected kv flags false by default")
    }
    if v, ok := rec.Config["alpha"]; !ok {
        t.Fatalf("expected merged alpha field")
    } else {
        // json.Unmarshal yields float64 for numbers
        if _, isNum := v.(float64); !isNum {
            t.Fatalf("expected alpha to be numeric, got %T", v)
        }
    }
}

func TestCreateServiceRecords_StatusSourceDoesNotMerge(t *testing.T) {
    s := &Server{logger: logger.NewTestLogger(), tracer: otel.Tracer("test")}
    now := time.Now()

    msg := []byte(`{"beta": true}`)
    apiSvc := &api.ServiceStatus{Name: "mapper", Type: "grpc", Message: msg}
    ps := &proto.ServiceStatus{ServiceName: "mapper", ServiceType: "grpc", AgentId: "agent-1", PollerId: "poller-1", Source: "status"}

    _, rec := s.createServiceRecords(context.Background(), ps, apiSvc, "poller-1", "default", "127.0.0.1", now)
    require.NotNil(t, rec)
    if _, ok := rec.Config["beta"]; ok {
        t.Fatalf("did not expect beta merged for non-config source")
    }
}

