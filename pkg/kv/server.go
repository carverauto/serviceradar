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

// Package kv pkg/kv/server.go
package kv

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Server implements the KVService gRPC interface and lifecycle.Service.
type Server struct {
	proto.UnimplementedKVServiceServer
	config *Config
	store  KVStore
}

func NewServer(ctx context.Context, cfg *Config) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	store, err := NewNatsStore(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create NATS store: %w", err)
	}

	return &Server{
		config: cfg,
		store:  store,
	}, nil
}

func (s *Server) Store() KVStore {
	return s.store
}

func (*Server) Start(_ context.Context) error {
	log.Printf("KV service initialized (gRPC managed by lifecycle)")

	return nil
}

func (s *Server) Stop(_ context.Context) error {
	log.Printf("Stopping KV service")

	return s.store.Close()
}

// Get implements the Get RPC.
func (s *Server) Get(ctx context.Context, req *proto.GetRequest) (*proto.GetResponse, error) {
	value, found, err := s.store.Get(ctx, req.Key)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get key %s: %v", req.Key, err)
	}

	return &proto.GetResponse{Value: value, Found: found}, nil
}

// Put implements the Put RPC.
func (s *Server) Put(ctx context.Context, req *proto.PutRequest) (*proto.PutResponse, error) {
	ttl := time.Duration(req.TtlSeconds) * time.Second

	err := s.store.Put(ctx, req.Key, req.Value, ttl)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to put key %s: %v", req.Key, err)
	}

	return &proto.PutResponse{}, nil
}

// PutMany implements the PutMany RPC.
func (s *Server) PutMany(ctx context.Context, req *proto.PutManyRequest) (*proto.PutManyResponse, error) {
	ttl := time.Duration(req.TtlSeconds) * time.Second

	entries := make([]KeyValueEntry, len(req.Entries))
	for i, e := range req.Entries {
		entries[i] = KeyValueEntry{Key: e.Key, Value: e.Value}
	}

	if err := s.store.PutMany(ctx, entries, ttl); err != nil {
		return nil, status.Errorf(codes.Internal, "failed to put many: %v", err)
	}

	return &proto.PutManyResponse{}, nil
}

// Delete implements the Delete RPC.
func (s *Server) Delete(ctx context.Context, req *proto.DeleteRequest) (*proto.DeleteResponse, error) {
	err := s.store.Delete(ctx, req.Key)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to delete key %s: %v", req.Key, err)
	}

	return &proto.DeleteResponse{}, nil
}

// Watch implements the Watch RPC.
func (s *Server) Watch(req *proto.WatchRequest, stream proto.KVService_WatchServer) error {
	watchChan, err := s.store.Watch(stream.Context(), req.Key)
	if err != nil {
		return status.Errorf(codes.Internal, "failed to watch key %s: %v", req.Key, err)
	}

	for {
		select {
		case <-stream.Context().Done():
			return nil
		case value, ok := <-watchChan:
			if !ok {
				return nil
			}

			err := stream.Send(&proto.WatchResponse{Value: value})
			if err != nil {
				return status.Errorf(codes.Internal, "failed to send watch update: %v", err)
			}
		}
	}
}
