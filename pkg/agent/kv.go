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
	"bytes"
	"context"
	"io"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// grpcRemoteStore adapts the gRPC KV/DataService clients to the agent interfaces.
type grpcRemoteStore struct {
	configClient proto.KVServiceClient
	objectClient proto.DataServiceClient
	conn         *grpc.Client
}

var (
	_ KVStore     = (*grpcRemoteStore)(nil)
	_ ObjectStore = (*grpcRemoteStore)(nil)
)

func (s *grpcRemoteStore) Get(ctx context.Context, key string) (value []byte, found bool, err error) {
	resp, err := s.configClient.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return nil, false, err
	}

	return resp.Value, resp.Found, nil
}

func (s *grpcRemoteStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	_, err := s.configClient.Put(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: int64(ttl / time.Second)})

	return err
}

// PutIfAbsent is available when KV server supports it; falls back to error if unimplemented.
func (s *grpcRemoteStore) PutIfAbsent(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	_, err := s.configClient.PutIfAbsent(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: int64(ttl / time.Second)})
	return err
}

func (s *grpcRemoteStore) Delete(ctx context.Context, key string) error {
	_, err := s.configClient.Delete(ctx, &proto.DeleteRequest{Key: key})

	return err
}

func (s *grpcRemoteStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	stream, err := s.configClient.Watch(ctx, &proto.WatchRequest{Key: key})
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

func (s *grpcRemoteStore) DownloadObject(ctx context.Context, key string) ([]byte, error) {
	if s.objectClient == nil {
		return nil, errDataServiceUnavailable
	}

	stream, err := s.objectClient.DownloadObject(ctx, &proto.DownloadObjectRequest{Key: key})
	if err != nil {
		return nil, translateDataServiceError(err)
	}

	var buf bytes.Buffer

	for {
		chunk, recvErr := stream.Recv()
		if recvErr == io.EOF {
			break
		}

		if recvErr != nil {
			return nil, translateDataServiceError(recvErr)
		}

		if data := chunk.GetData(); len(data) > 0 {
			if _, writeErr := buf.Write(data); writeErr != nil {
				return nil, writeErr
			}
		}

		if chunk.GetIsFinal() {
			break
		}
	}

	return buf.Bytes(), nil
}

func (s *grpcRemoteStore) Close() error {
	return s.conn.Close()
}

func translateDataServiceError(err error) error {
	if err == nil {
		return nil
	}

	if st, ok := status.FromError(err); ok {
		switch st.Code() {
		case codes.Unimplemented, codes.NotFound, codes.PermissionDenied, codes.FailedPrecondition:
			return errDataServiceUnavailable
		}
	}

	return err
}
