/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/proto"
)

// grpcKVStore adapts the gRPC KV client to the KVStore interface.
type grpcKVStore struct {
    client proto.KVServiceClient
    conn   *grpc.Client
}

var _ KVStore = (*grpcKVStore)(nil) // Ensure grpcKVStore implements KVStore

func (g *grpcKVStore) Get(ctx context.Context, key string) (value []byte, found bool, err error) {
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

// PutIfAbsent is available when KV server supports it; falls back to error if unimplemented.
func (g *grpcKVStore) PutIfAbsent(ctx context.Context, key string, value []byte, ttl time.Duration) error {
    _, err := g.client.PutIfAbsent(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: int64(ttl / time.Second)})
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
