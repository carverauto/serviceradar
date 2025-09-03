package kvgrpc

import (
    "context"
    "time"

    "github.com/carverauto/serviceradar/pkg/config/kv"
    "github.com/carverauto/serviceradar/proto"
)

// Client adapts a proto.KVServiceClient to the pkg/config/kv.KVStore interface.
type Client struct {
    c      proto.KVServiceClient
    closer func() error
}

// Ensure Client implements kv.KVStore
var _ kv.KVStore = (*Client)(nil)

// New creates a new KV adapter client.
func New(c proto.KVServiceClient, closer func() error) *Client {
    return &Client{c: c, closer: closer}
}

func (k *Client) Get(ctx context.Context, key string) ([]byte, bool, error) {
    resp, err := k.c.Get(ctx, &proto.GetRequest{Key: key})
    if err != nil {
        return nil, false, err
    }
    return resp.Value, resp.Found, nil
}

func (k *Client) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
    _, err := k.c.Put(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: int64(ttl / time.Second)})
    return err
}

func (k *Client) Delete(ctx context.Context, key string) error {
    _, err := k.c.Delete(ctx, &proto.DeleteRequest{Key: key})
    return err
}

func (k *Client) Watch(ctx context.Context, key string) (<-chan []byte, error) {
    stream, err := k.c.Watch(ctx, &proto.WatchRequest{Key: key})
    if err != nil {
        return nil, err
    }
    ch := make(chan []byte, 1)
    go func() {
        defer close(ch)
        for {
            resp, err := stream.Recv()
            if err != nil {
                return
            }
            select {
            case ch <- resp.Value:
            case <-ctx.Done():
                return
            }
        }
    }()
    return ch, nil
}

func (k *Client) Close() error {
    if k.closer != nil {
        return k.closer()
    }
    return nil
}
