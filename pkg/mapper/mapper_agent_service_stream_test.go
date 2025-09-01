package mapper

import (
    "context"
    "encoding/json"
    "testing"
    "google.golang.org/grpc/metadata"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/proto"
)

type capMapperStream struct{ chunks []*proto.ConfigChunk }

func (c *capMapperStream) Send(ch *proto.ConfigChunk) error { c.chunks = append(c.chunks, ch); return nil }
func (c *capMapperStream) SetHeader(_ metadata.MD) error { return nil }
func (c *capMapperStream) SendHeader(_ metadata.MD) error { return nil }
func (c *capMapperStream) SetTrailer(_ metadata.MD) {}
func (c *capMapperStream) Context() context.Context { return context.Background() }
func (c *capMapperStream) SendMsg(_ any) error { return nil }
func (c *capMapperStream) RecvMsg(_ any) error { return nil }

func TestMapperAgentService_StreamConfig_SendsSingleChunk(t *testing.T) {
    t.Parallel()

    eng := &DiscoveryEngine{config: &Config{Workers: 3, }}
    svc := NewAgentService(eng)

    stream := &capMapperStream{}
    err := svc.StreamConfig(&proto.ConfigRequest{ServiceName: "mapper", ServiceType: "grpc"}, stream)
    require.NoError(t, err)
    require.Len(t, stream.chunks, 1)
    require.True(t, stream.chunks[0].IsFinal)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(stream.chunks[0].Data, &decoded))
}

