/*-
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

// Package grpc pkg/grpc/server.go
package grpc

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

// ServerOption is a function type that modifies Server configuration.
type ServerOption func(*Server)

var (
	errInternalError          = fmt.Errorf("internal error")
	errHealthServerRegistered = fmt.Errorf("health server already registered")
)

const (
	shutdownTimer = 5 * time.Second
)

// Server wraps a gRPC server with additional functionality.
type Server struct {
	srv         *grpc.Server
	healthCheck *health.Server
	addr        string
	mu          sync.RWMutex
	services    map[string]struct{}
	serverOpts  []grpc.ServerOption // Store server options
}

func NewServer(addr string, opts ...ServerOption) *Server {
	// Initialize with default interceptors
	defaultOpts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			LoggingInterceptor,
			RecoveryInterceptor,
		),
	}

	s := &Server{
		addr:       addr,
		services:   make(map[string]struct{}),
		serverOpts: defaultOpts,
	}

	// Apply custom options
	for _, opt := range opts {
		opt(s)
	}

	// Create the gRPC server with all options
	s.srv = grpc.NewServer(s.serverOpts...)

	// Enable reflection for debugging
	reflection.Register(s.srv)

	return s
}

// GetGRPCServer returns the underlying gRPC server.
func (s *Server) GetGRPCServer() *grpc.Server {
	return s.srv
}

func (s *Server) RegisterHealthServer(healthServer healthpb.HealthServer) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Only register health server if not already registered
	if s.healthCheck != nil {
		return errHealthServerRegistered
	}

	healthpb.RegisterHealthServer(s.srv, healthServer)

	return nil
}

// WithServerOptions adds gRPC server options.
func WithServerOptions(opt ...grpc.ServerOption) ServerOption {
	return func(s *Server) {
		s.serverOpts = append(s.serverOpts, opt...)
	}
}

// WithMaxRecvSize sets the maximum receive message size.
func WithMaxRecvSize(size int) ServerOption {
	return func(s *Server) {
		s.serverOpts = append(s.serverOpts, grpc.MaxRecvMsgSize(size))
	}
}

// WithMaxSendSize sets the maximum send message size.
func WithMaxSendSize(size int) ServerOption {
	return func(s *Server) {
		s.serverOpts = append(s.serverOpts, grpc.MaxSendMsgSize(size))
	}
}

// RegisterService registers a service with the gRPC server.
func (s *Server) RegisterService(desc *grpc.ServiceDesc, impl interface{}) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.services[desc.ServiceName] = struct{}{}
	s.srv.RegisterService(desc, impl)

	// Only set health status if health check is initialized
	if s.healthCheck != nil {
		s.healthCheck.SetServingStatus(desc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	}
}

// Start starts the gRPC server.
func (s *Server) Start() error {
	lis, err := net.Listen("tcp", s.addr)
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}

	log.Printf("gRPC server listening on %s", s.addr)

	if err := s.srv.Serve(lis); err != nil {
		return fmt.Errorf("failed to serve: %w", err)
	}

	return nil
}

// Stop gracefully stops the gRPC server.
func (s *Server) Stop(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// set a timeout on the context
	_, cancel := context.WithTimeout(ctx, shutdownTimer)
	defer cancel()

	// Mark all services as not serving if health check is initialized
	if s.healthCheck != nil {
		for service := range s.services {
			s.healthCheck.SetServingStatus(service, healthpb.HealthCheckResponse_NOT_SERVING)
		}
	}

	s.srv.GracefulStop()
}

// LoggingInterceptor logs RPC calls.
func LoggingInterceptor(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
	start := time.Now()
	resp, err := handler(ctx, req)
	log.Printf("gRPC call: %s Duration: %v Error: %v",
		info.FullMethod,
		time.Since(start),
		err)

	return resp, err
}

// RecoveryInterceptor handles panics in RPC handlers.
func RecoveryInterceptor(
	ctx context.Context,
	req interface{},
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler) (resp interface{}, err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Recovered from panic in %s: %v", info.FullMethod, r)

			err = errInternalError
		}
	}()

	return handler(ctx, req)
}
