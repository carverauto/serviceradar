package dbeventwriter

import (
    "context"
    "encoding/json"
    "testing"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
)

func TestAgentService_GetConfig_JSON(t *testing.T) {
    t.Parallel()

    cfg := &DBEventWriterConfig{
        ListenAddr:   ":0",
        NATSURL:      "nats://localhost:4222",
        StreamName:   "events",
        ConsumerName: "writer",
        Database:     models.ProtonDatabase{Name: "serviceradar", Addresses: []string{"localhost:8123"}},
        Logging:      &logger.Config{Level: "debug"},
    }
    svc := &Service{cfg: cfg, logger: logger.NewTestLogger()}
    as := NewAgentService(svc)

    resp, err := as.GetConfig(context.Background(), &proto.ConfigRequest{ServiceName: "db-event-writer", ServiceType: "grpc"})
    require.NoError(t, err)
    require.NotNil(t, resp)
    require.NotEmpty(t, resp.Config)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(resp.Config, &decoded))
    if _, ok := decoded["listen_addr"]; !ok {
        t.Fatalf("expected listen_addr in db-event-writer config JSON")
    }
}
