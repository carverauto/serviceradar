package agent

import (
    "context"
    "encoding/json"
    "testing"

    "github.com/stretchr/testify/require"
    "google.golang.org/grpc"
    "google.golang.org/grpc/metadata"

    "github.com/carverauto/serviceradar/proto"
)

type capAgentConfigStream struct{ 
    grpc.ServerStream
    chunks []*proto.ConfigChunk 
    ctx context.Context
}

func (c *capAgentConfigStream) Send(ch *proto.ConfigChunk) error { c.chunks = append(c.chunks, ch); return nil }
func (c *capAgentConfigStream) Context() context.Context { 
    if c.ctx == nil {
        return context.Background()
    }
    return c.ctx 
}
func (c *capAgentConfigStream) SetHeader(metadata.MD) error { return nil }
func (c *capAgentConfigStream) SendHeader(metadata.MD) error { return nil }
func (c *capAgentConfigStream) SetTrailer(metadata.MD) {}
func (c *capAgentConfigStream) SendMsg(m any) error { return nil }
func (c *capAgentConfigStream) RecvMsg(m any) error { return nil }

func TestServer_StreamConfig_SendsSingleChunk(t *testing.T) {
    t.Parallel()

    s := &Server{config: &ServerConfig{ListenAddr: ":0", AgentID: "agent-1"}}
    stream := &capAgentConfigStream{}

    err := s.StreamConfig(&proto.ConfigRequest{ServiceName: "serviceradar-agent", ServiceType: "process"}, stream)
    require.NoError(t, err)
    require.Len(t, stream.chunks, 1)
    require.True(t, stream.chunks[0].IsFinal)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(stream.chunks[0].Data, &decoded))
    if decoded["agent_id"] != "agent-1" {
        t.Fatalf("expected agent_id=agent-1 in JSON, got %v", decoded["agent_id"])
    }
}

