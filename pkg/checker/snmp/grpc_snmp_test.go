package snmp

import (
    "context"
    "encoding/json"
    "testing"
    "time"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/proto"
    "github.com/carverauto/serviceradar/pkg/models"
)

func TestPollerService_GetConfig_JSON(t *testing.T) {
    t.Parallel()

    // Minimal SNMP config
    checker := &Poller{Config: SNMPConfig{Timeout: models.Duration(2 * time.Second)}}
    svc := &PollerService{checker: checker}

    resp, err := svc.GetConfig(context.Background(), &proto.ConfigRequest{ServiceName: "snmp", ServiceType: "snmp"})
    require.NoError(t, err)
    require.NotNil(t, resp)
    require.NotEmpty(t, resp.Config)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(resp.Config, &decoded))
}

