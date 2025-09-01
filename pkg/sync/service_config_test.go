package sync

import (
    "context"
    "encoding/json"
    "testing"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
)

func TestSimpleSyncService_GetConfig_JSON(t *testing.T) {
    t.Parallel()

    ctx := context.Background()
    log := logger.NewTestLogger()

    cfg := &Config{
        ListenAddr: ":0",
        Sources:    map[string]*models.SourceConfig{"dummy": {Type: "dummy", Endpoint: "http://example"}},
    }

    // Build a minimal service instance (we don't need kvClient/registry for GetConfig)
    svc, err := NewSimpleSyncService(ctx, cfg, nil, nil, nil, log)
    require.NoError(t, err)

    req := &proto.ConfigRequest{ServiceName: "sync", ServiceType: "grpc", AgentId: "agent-1", PollerId: "poller-1"}
    resp, err := svc.GetConfig(ctx, req)
    require.NoError(t, err)
    require.NotNil(t, resp)
    require.NotEmpty(t, resp.Config)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(resp.Config, &decoded))
    require.Equal(t, ":0", decoded["listen_addr"])
}
