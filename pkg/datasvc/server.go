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

// Package datasvc implements the gRPC server for the data service (KV + object store).
package datasvc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"github.com/rs/zerolog"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Server implements the KVService gRPC interface and lifecycle.Service.
type Server struct {
	proto.UnimplementedKVServiceServer
	proto.UnimplementedDataServiceServer
	config *Config
	store  KVStore
	logger logger.Logger
}

func NewServer(ctx context.Context, cfg *Config) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	store, err := NewNATSStore(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create NATS store: %w", err)
	}

	// Create logger for datasvc
	zlog := zerolog.New(os.Stderr).With().Timestamp().Str("service", "datasvc").Logger()
	dsLogger := &datasvcLogger{logger: zlog}

	return &Server{
		config: cfg,
		store:  store,
		logger: dsLogger,
	}, nil
}

// datasvcLogger wraps zerolog to implement logger.Logger interface
type datasvcLogger struct {
	logger zerolog.Logger
}

func (l *datasvcLogger) Trace() *zerolog.Event                                { return l.logger.Trace() }
func (l *datasvcLogger) Debug() *zerolog.Event                                { return l.logger.Debug() }
func (l *datasvcLogger) Info() *zerolog.Event                                 { return l.logger.Info() }
func (l *datasvcLogger) Warn() *zerolog.Event                                 { return l.logger.Warn() }
func (l *datasvcLogger) Error() *zerolog.Event                                { return l.logger.Error() }
func (l *datasvcLogger) Fatal() *zerolog.Event                                { return l.logger.Fatal() }
func (l *datasvcLogger) Panic() *zerolog.Event                                { return l.logger.Panic() }
func (l *datasvcLogger) With() zerolog.Context                                { return l.logger.With() }
func (l *datasvcLogger) WithComponent(component string) zerolog.Logger        { return l.logger.With().Str("component", component).Logger() }
func (l *datasvcLogger) WithFields(fields map[string]interface{}) zerolog.Logger {
	ctx := l.logger.With()
	for k, v := range fields {
		ctx = ctx.Interface(k, v)
	}
	return ctx.Logger()
}
func (l *datasvcLogger) SetLevel(level zerolog.Level) { l.logger = l.logger.Level(level) }
func (l *datasvcLogger) SetDebug(debug bool) {
	if debug {
		l.logger = l.logger.Level(zerolog.DebugLevel)
	}
}

func (s *Server) Store() KVStore {
	return s.store
}

func (s *Server) Start(ctx context.Context) error {
	log.Printf("KV service initialized (gRPC managed by lifecycle)")

	// Start Core registration if configured
	if s.config.CoreRegistration != nil {
		s.StartCoreRegistration(ctx, s.config.CoreRegistration, s.config.ListenAddr, s.config.Security)
	}

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
func (s *Server) Info(_ context.Context, _ *proto.InfoRequest) (*proto.InfoResponse, error) {
	return &proto.InfoResponse{
		Domain:       s.config.Domain,
		Bucket:       s.config.Bucket,
		ObjectBucket: s.config.ObjectBucket,
	}, nil
}

// UploadObject implements the client-streaming object upload RPC.
func (s *Server) UploadObject(stream proto.DataService_UploadObjectServer) error {
	firstChunk, err := stream.Recv()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return status.Error(codes.InvalidArgument, "upload requires at least one chunk")
		}
		return status.Errorf(codes.Internal, "failed to receive upload chunk: %v", err)
	}

	meta := firstChunk.GetMetadata()
	if meta == nil || meta.GetKey() == "" {
		return status.Error(codes.InvalidArgument, "first upload chunk must include metadata with key")
	}

	storeMeta := protoToObjectMetadata(meta)
	reader, writer := io.Pipe()
	writeErrCh := make(chan error, 1)

	go func(initial *proto.ObjectUploadChunk) {
		defer close(writeErrCh)
		defer func() {
			_ = writer.Close()
		}()

		chunk := initial
		for {
			if data := chunk.GetData(); len(data) > 0 {
				if _, err := writer.Write(data); err != nil {
					writeErrCh <- err
					return
				}
			}

			if chunk.GetIsFinal() {
				writeErrCh <- nil
				return
			}

			next, err := stream.Recv()
			if err != nil {
				if errors.Is(err, io.EOF) {
					writeErrCh <- nil
				} else {
					writeErrCh <- err
				}
				return
			}

			if next.Metadata != nil {
				mergeProtoMetadata(storeMeta, next.Metadata)
			}

			chunk = next
		}
	}(firstChunk)

	info, putErr := s.store.PutObject(stream.Context(), meta.GetKey(), reader, *storeMeta)
	if putErr != nil {
		_ = reader.CloseWithError(putErr)
	}

	writeErr := <-writeErrCh
	if putErr != nil {
		return status.Errorf(codes.Internal, "failed to store object %s: %v", meta.GetKey(), putErr)
	}
	if writeErr != nil {
		return status.Errorf(codes.Internal, "failed to stream object %s: %v", meta.GetKey(), writeErr)
	}

	resp := &proto.UploadObjectResponse{Info: objectInfoToProto(info)}
	if err := stream.SendAndClose(resp); err != nil {
		return status.Errorf(codes.Internal, "failed to send upload response: %v", err)
	}

	return nil
}

// DownloadObject streams an object to the caller.
func (s *Server) DownloadObject(req *proto.DownloadObjectRequest, stream proto.DataService_DownloadObjectServer) error {
	reader, info, err := s.store.GetObject(stream.Context(), req.GetKey())
	if err != nil {
		if errors.Is(err, ErrObjectNotFound) {
			return status.Errorf(codes.NotFound, "object %s not found", req.GetKey())
		}
		return status.Errorf(codes.Internal, "failed to fetch object %s: %v", req.GetKey(), err)
	}
	if reader == nil {
		return status.Errorf(codes.Internal, "object %s returned no data", req.GetKey())
	}
	defer func() {
		_ = reader.Close()
	}()

	protoInfo := objectInfoToProto(info)
	buf := make([]byte, 1024*1024)
	var chunkIndex uint32

	for {
		n, readErr := reader.Read(buf)
		if n > 0 {
			chunk := &proto.ObjectDownloadChunk{
				Data:       append([]byte(nil), buf[:n]...),
				ChunkIndex: chunkIndex,
			}
			if chunkIndex == 0 {
				chunk.Info = protoInfo
			}
			if errors.Is(readErr, io.EOF) {
				chunk.IsFinal = true
			}
			if err := stream.Send(chunk); err != nil {
				return status.Errorf(codes.Internal, "failed to stream object chunk: %v", err)
			}
			chunkIndex++
		}

		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			return status.Errorf(codes.Internal, "failed to read object %s: %v", req.GetKey(), readErr)
		}
	}

	if chunkIndex == 0 {
		chunk := &proto.ObjectDownloadChunk{
			Info:    protoInfo,
			IsFinal: true,
		}
		if err := stream.Send(chunk); err != nil {
			return status.Errorf(codes.Internal, "failed to stream empty object metadata: %v", err)
		}
	}

	return nil
}

// DeleteObject removes an object from the store.
func (s *Server) DeleteObject(ctx context.Context, req *proto.DeleteObjectRequest) (*proto.DeleteObjectResponse, error) {
	if err := s.store.DeleteObject(ctx, req.GetKey()); err != nil {
		if errors.Is(err, ErrObjectNotFound) {
			return &proto.DeleteObjectResponse{Deleted: false}, nil
		}
		return nil, status.Errorf(codes.Internal, "failed to delete object %s: %v", req.GetKey(), err)
	}

	return &proto.DeleteObjectResponse{Deleted: true}, nil
}

// GetObjectInfo retrieves metadata describing an object.
func (s *Server) GetObjectInfo(ctx context.Context, req *proto.GetObjectInfoRequest) (*proto.GetObjectInfoResponse, error) {
	info, found, err := s.store.GetObjectInfo(ctx, req.GetKey())
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to inspect object %s: %v", req.GetKey(), err)
	}
	if !found {
		return &proto.GetObjectInfoResponse{Found: false}, nil
	}

	return &proto.GetObjectInfoResponse{
		Info:  objectInfoToProto(info),
		Found: true,
	}, nil
}

func protoToObjectMetadata(meta *proto.ObjectMetadata) *ObjectMetadata {
	if meta == nil {
		return &ObjectMetadata{}
	}

	result := &ObjectMetadata{
		Domain:      meta.GetDomain(),
		ContentType: meta.GetContentType(),
		Compression: meta.GetCompression(),
		SHA256:      meta.GetSha256(),
		TotalSize:   meta.GetTotalSize(),
	}

	if attrs := meta.GetAttributes(); len(attrs) > 0 {
		result.Attributes = make(map[string]string, len(attrs))
		for k, v := range attrs {
			result.Attributes[k] = v
		}
	}

	return result
}

func mergeProtoMetadata(dst *ObjectMetadata, src *proto.ObjectMetadata) {
	if src == nil {
		return
	}

	if d := src.GetDomain(); d != "" {
		dst.Domain = d
	}
	if ct := src.GetContentType(); ct != "" {
		dst.ContentType = ct
	}
	if cmp := src.GetCompression(); cmp != "" {
		dst.Compression = cmp
	}
	if sum := src.GetSha256(); sum != "" {
		dst.SHA256 = sum
	}
	if size := src.GetTotalSize(); size > 0 {
		dst.TotalSize = size
	}
	if attrs := src.GetAttributes(); len(attrs) > 0 {
		if dst.Attributes == nil {
			dst.Attributes = make(map[string]string, len(attrs))
		}
		for k, v := range attrs {
			dst.Attributes[k] = v
		}
	}
}

func objectInfoToProto(info *ObjectInfo) *proto.ObjectInfo {
	if info == nil {
		return nil
	}

	meta := &proto.ObjectMetadata{
		Key:         info.Key,
		Domain:      info.Domain,
		ContentType: info.Metadata.ContentType,
		Compression: info.Metadata.Compression,
		Sha256:      info.Metadata.SHA256,
		TotalSize:   info.Metadata.TotalSize,
	}

	if attrs := info.Metadata.Attributes; len(attrs) > 0 {
		meta.Attributes = make(map[string]string, len(attrs))
		for k, v := range attrs {
			meta.Attributes[k] = v
		}
	}

	return &proto.ObjectInfo{
		Metadata:       meta,
		Sha256:         info.SHA256,
		Size:           info.Size,
		CreatedAtUnix:  info.CreatedAtUnix,
		ModifiedAtUnix: info.ModifiedAtUnix,
		Chunks:         info.Chunks,
	}
}
