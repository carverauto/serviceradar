package snmp

import (
    "context"
    "encoding/json"
    "testing"
    "time"

    "github.com/stretchr/testify/require"

    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
    "google.golang.org/grpc/metadata"
)

type capSNMPStream struct{ chunks []*proto.ConfigChunk }

func (c *capSNMPStream) Send(ch *proto.ConfigChunk) error { c.chunks = append(c.chunks, ch); return nil }
func (c *capSNMPStream) SetHeader(_ metadata.MD) error { return nil }
func (c *capSNMPStream) SendHeader(_ metadata.MD) error { return nil }
func (c *capSNMPStream) SetTrailer(_ metadata.MD) {}
func (c *capSNMPStream) Context() context.Context { return context.Background() }
func (c *capSNMPStream) SendMsg(_ any) error { return nil }
func (c *capSNMPStream) RecvMsg(_ any) error { return nil }

func TestPollerService_StreamConfig_SendsSingleChunk(t *testing.T) {
    t.Parallel()

    checker := &Poller{Config: SNMPConfig{Timeout: models.Duration(1 * time.Second)}}
    svc := &PollerService{checker: checker}

    stream := &capSNMPStream{}
    err := svc.StreamConfig(&proto.ConfigRequest{ServiceName: "snmp", ServiceType: "snmp"}, stream)
    require.NoError(t, err)
    require.Len(t, stream.chunks, 1)
    require.True(t, stream.chunks[0].IsFinal)

    var decoded map[string]any
    require.NoError(t, json.Unmarshal(stream.chunks[0].Data, &decoded))
}

