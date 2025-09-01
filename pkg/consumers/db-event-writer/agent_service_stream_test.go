package dbeventwriter

import (
    "context"
    "encoding/json"
    "testing"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
    "google.golang.org/grpc/metadata"
)

type capDBWriterStream struct{ chunks []*proto.ConfigChunk }

func (c *capDBWriterStream) Send(ch *proto.ConfigChunk) error { c.chunks = append(c.chunks, ch); return nil }
func (c *capDBWriterStream) SetHeader(_ metadata.MD) error { return nil }
func (c *capDBWriterStream) SendHeader(_ metadata.MD) error { return nil }
func (c *capDBWriterStream) SetTrailer(_ metadata.MD) {}
func (c *capDBWriterStream) Context() context.Context { return context.Background() }
func (c *capDBWriterStream) SendMsg(m any) error { return nil }
func (c *capDBWriterStream) RecvMsg(m any) error { return nil }

func TestAgentService_StreamConfig_SendsSingleChunk(t *testing.T) {
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

    stream := &capDBWriterStream{}
    err := as.StreamConfig(&proto.ConfigRequest{ServiceName: "db-event-writer", ServiceType: "grpc"}, stream)
    require.NoError(t, err)
    require.Len(t, stream.chunks, 1)
    require.True(t, stream.chunks[0].IsFinal)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(stream.chunks[0].Data, &decoded))
}

