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
	"errors"
	"fmt"
	"log"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/proto"
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

	store, err := NewNATSStore(ctx, cfg)
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
	entry, err := s.store.GetEntry(ctx, req.Key)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get key %s: %v", req.Key, err)
	}

	resp := &proto.GetResponse{Value: entry.Value, Found: entry.Found}
	if entry.Found {
		resp.Revision = entry.Revision
	}

	return resp, nil
}

// BatchGet implements the BatchGet RPC.
func (s *Server) BatchGet(ctx context.Context, req *proto.BatchGetRequest) (*proto.BatchGetResponse, error) {
	results := make([]*proto.BatchGetEntry, 0, len(req.GetKeys()))

	for _, key := range req.GetKeys() {
		entry, err := s.store.GetEntry(ctx, key)
		if err != nil {
			return nil, status.Errorf(codes.Internal, "failed to get key %s: %v", key, err)
		}

		batchEntry := &proto.BatchGetEntry{Key: key, Found: entry.Found}
		if entry.Found {
			batchEntry.Value = entry.Value
			batchEntry.Revision = entry.Revision
		}

		results = append(results, batchEntry)
	}

	return &proto.BatchGetResponse{Results: results}, nil
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

// PutIfAbsent implements the PutIfAbsent RPC.
func (s *Server) PutIfAbsent(ctx context.Context, req *proto.PutRequest) (*proto.PutResponse, error) {
	ttl := time.Duration(req.TtlSeconds) * time.Second

	if err := s.store.PutIfAbsent(ctx, req.Key, req.Value, ttl); err != nil {
		if errors.Is(err, ErrKeyExists) {
			return nil, status.Errorf(codes.AlreadyExists, "key %s already exists", req.Key)
		}
		return nil, status.Errorf(codes.Internal, "failed to put-if-absent key %s: %v", req.Key, err)
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

// Update implements the Update (CAS) RPC.
func (s *Server) Update(ctx context.Context, req *proto.UpdateRequest) (*proto.UpdateResponse, error) {
	ttl := time.Duration(req.TtlSeconds) * time.Second

	revision, err := s.store.Update(ctx, req.Key, req.Value, req.Revision, ttl)
	if err != nil {
		if errors.Is(err, ErrCASMismatch) {
			return nil, status.Errorf(codes.Aborted, "cas mismatch for key %s", req.Key)
		}
		return nil, status.Errorf(codes.Internal, "failed to update key %s: %v", req.Key, err)
	}

	return &proto.UpdateResponse{Revision: revision}, nil
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

// Info implements the Info RPC (domain and bucket for introspection).
// Note: Requires proto regeneration to compile the new types.
func (s *Server) Info(_ context.Context, _ *proto.InfoRequest) (*proto.InfoResponse, error) {
	// We expose the configured domain and bucket from the server's cfg
	domain := s.config.Domain
	bucket := s.config.Bucket
	return &proto.InfoResponse{Domain: domain, Bucket: bucket}, nil
}
