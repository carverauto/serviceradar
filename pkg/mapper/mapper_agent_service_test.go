package mapper

import (
    "context"
    "encoding/json"
    "testing"
    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/proto"
)

func TestMapperAgentService_GetConfig_JSON(t *testing.T) {
    t.Parallel()

    eng := &DiscoveryEngine{config: &Config{Workers: 2, }}
    svc := NewAgentService(eng)

    resp, err := svc.GetConfig(context.Background(), &proto.ConfigRequest{ServiceName: "mapper", ServiceType: "grpc"})
    require.NoError(t, err)
    require.NotNil(t, resp)
    require.NotEmpty(t, resp.Config)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(resp.Config, &decoded))
    if _, ok := decoded["workers"]; !ok {
        t.Fatalf("expected workers in mapper config JSON")
    }
}
