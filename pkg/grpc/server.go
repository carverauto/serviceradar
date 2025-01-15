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
	errInternalError = fmt.Errorf("internal error")
)

// Server wraps a gRPC server with additional functionality.
type Server struct {
	srv         *grpc.Server
	healthCheck *health.Server
	addr        string
	mu          sync.RWMutex
	services    map[string]struct{}
}

// NewServer creates a new gRPC server with the provided options.
func NewServer(addr string, opts ...ServerOption) *Server {
	// Create server with default interceptors
	serverOpts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			LoggingInterceptor,
			RecoveryInterceptor,
		),
	}

	s := &Server{
		srv:         grpc.NewServer(serverOpts...),
		healthCheck: health.NewServer(),
		addr:        addr,
		services:    make(map[string]struct{}),
	}

	// Apply custom options
	for _, opt := range opts {
		opt(s)
	}

	// Register health check service
	healthpb.RegisterHealthServer(s.srv, s.healthCheck)

	// Enable reflection for debugging
	reflection.Register(s.srv)

	return s
}

// WithMaxRecvSize sets the maximum receive message size.
func WithMaxRecvSize(size int) ServerOption {
	return func(s *Server) {
		s.srv.GracefulStop()
		s.srv = grpc.NewServer(grpc.MaxRecvMsgSize(size))
	}
}

// WithMaxSendSize sets the maximum send message size.
func WithMaxSendSize(size int) ServerOption {
	return func(s *Server) {
		s.srv.GracefulStop()
		s.srv = grpc.NewServer(grpc.MaxSendMsgSize(size))
	}
}

// RegisterService registers a service with the gRPC server.
func (s *Server) RegisterService(desc *grpc.ServiceDesc, impl interface{}) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.services[desc.ServiceName] = struct{}{}
	s.srv.RegisterService(desc, impl)
	s.healthCheck.SetServingStatus(desc.ServiceName, healthpb.HealthCheckResponse_SERVING)
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
func (s *Server) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Mark all services as not serving
	for service := range s.services {
		s.healthCheck.SetServingStatus(service, healthpb.HealthCheckResponse_NOT_SERVING)
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
