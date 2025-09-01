package sync

import (
    "context"
    "encoding/json"
    "testing"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
    gmetadata "google.golang.org/grpc/metadata"
)

type captureConfigStream struct{ chunks []*proto.ConfigChunk }

func (c *captureConfigStream) Send(ch *proto.ConfigChunk) error { c.chunks = append(c.chunks, ch); return nil }
func (c *captureConfigStream) SetHeader(_ gmetadata.MD) error { return nil }
func (c *captureConfigStream) SendHeader(_ gmetadata.MD) error { return nil }
func (c *captureConfigStream) SetTrailer(_ gmetadata.MD) {}
func (c *captureConfigStream) Context() context.Context { return context.Background() }
func (c *captureConfigStream) SendMsg(_ any) error { return nil }
func (c *captureConfigStream) RecvMsg(_ any) error { return nil }

func TestSimpleSyncService_StreamConfig_SendsSingleChunk(t *testing.T) {
    t.Parallel()

    ctx := context.Background()
    log := logger.NewTestLogger()

    cfg := &Config{ListenAddr: ":0", Sources: map[string]*models.SourceConfig{"dummy": {Type: "dummy", Endpoint: "http://example"}}}
    svc, err := NewSimpleSyncService(ctx, cfg, nil, nil, nil, log)
    require.NoError(t, err)

    stream := &captureConfigStream{}
    req := &proto.ConfigRequest{ServiceName: "sync", ServiceType: "grpc"}
    err = svc.StreamConfig(req, stream)
    require.NoError(t, err)
    require.Len(t, stream.chunks, 1)
    require.True(t, stream.chunks[0].IsFinal)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(stream.chunks[0].Data, &decoded))
    require.Equal(t, ":0", decoded["listen_addr"])
}

