package agent

import (
	"context"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/proto"
)

// grpcKVStore adapts the gRPC KV client to the KVStore interface.
type grpcKVStore struct {
	client proto.KVServiceClient
	conn   *grpc.Client
}

func (g *grpcKVStore) Get(ctx context.Context, key string) (value []byte, found bool, err error) {
	log.Printf("KV Get: key=%s, using client=%p", key, g.client)

	resp, err := g.client.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return nil, false, err
	}

	return resp.Value, resp.Found, nil
}

func (g *grpcKVStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	_, err := g.client.Put(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: int64(ttl / time.Second)})

	return err
}

func (g *grpcKVStore) Delete(ctx context.Context, key string) error {
	_, err := g.client.Delete(ctx, &proto.DeleteRequest{Key: key})

	return err
}

func (g *grpcKVStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	stream, err := g.client.Watch(ctx, &proto.WatchRequest{Key: key})
	if err != nil {
		return nil, err
	}

	ch := make(chan []byte)

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

func (g *grpcKVStore) Close() error {
	return g.conn.Close()
}
