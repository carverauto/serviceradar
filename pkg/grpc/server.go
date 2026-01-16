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

// Package grpc pkg/grpc/server.go
package grpc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/reflection"
	grpcstats "google.golang.org/grpc/stats"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// ServerOption is a function type that modifies Server configuration.
type ServerOption func(*Server)

// Add a private context key to safely store and retrieve the logger.
type loggerKey struct{}

// GetLogger extracts the trace-aware logger from context, falls back to default if not found
func GetLogger(ctx context.Context, defaultLogger logger.Logger) logger.Logger {
	if l, ok := ctx.Value(loggerKey{}).(logger.Logger); ok {
		return l
	}

	return defaultLogger
}

var (
	errInternalError          = fmt.Errorf("internal error")
	errHealthServerRegistered = fmt.Errorf("health server already registered")
	errServerStopped          = errors.New("server stopped")
)

const (
	shutdownTimer = 5 * time.Second
)

// Server wraps a gRPC server with additional functionality.
type Server struct {
	srv               *grpc.Server
	healthCheck       *health.Server
	addr              string
	logger            logger.Logger
	mu                sync.RWMutex
	services          map[string]struct{}
	serverOpts        []grpc.ServerOption // Store server options
	healthRegistered  bool
	telemetryDisabled bool
	telemetryFilter   TelemetryFilter
}

// NewServer creates a new gRPC server with the given configuration.
func NewServer(addr string, log logger.Logger, opts ...ServerOption) *Server {
	s := &Server{
		addr:             addr,
		logger:           log,
		services:         make(map[string]struct{}),
		healthRegistered: false,
	}

	// Apply custom options
	for _, opt := range opts {
		opt(s)
	}

	// Initialize with default interceptors
	defaultOpts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			LoggingInterceptor(log),
			RecoveryInterceptor(log),
		),
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionIdle:     10 * time.Minute,
			MaxConnectionAge:      24 * time.Hour,
			MaxConnectionAgeGrace: 5 * time.Minute,
			Time:                  120 * time.Second,
			Timeout:               20 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime:             120 * time.Second,
			PermitWithoutStream: true,
		}),
	}

	if !s.telemetryDisabled {
		handlerOpts := []otelgrpc.Option{}
		if s.telemetryFilter != nil {
			handlerOpts = append(handlerOpts, otelgrpc.WithFilter(func(info *grpcstats.RPCTagInfo) bool {
				return s.telemetryFilter(info)
			}))
		}

		defaultOpts = append([]grpc.ServerOption{grpc.StatsHandler(otelgrpc.NewServerHandler(handlerOpts...))}, defaultOpts...)
	}

	s.serverOpts = append(defaultOpts, s.serverOpts...)

	// Create the gRPC server with all options
	s.srv = grpc.NewServer(s.serverOpts...)

	// Create health service but don't register yet
	s.healthCheck = health.NewServer()

	// Enable reflection for debugging
	reflection.Register(s.srv)

	return s
}

// GetGRPCServer returns the underlying gRPC server.
func (s *Server) GetGRPCServer() *grpc.Server {
	return s.srv
}

// GetHealthCheck returns the health server instance.
func (s *Server) GetHealthCheck() *health.Server {
	return s.healthCheck
}

// RegisterHealthServer registers the health server if not already registered.
func (s *Server) RegisterHealthServer() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.healthRegistered {
		s.logger.Info().Msg("Health server already registered, skipping")

		return errHealthServerRegistered
	}

	s.logger.Info().Str("addr", s.addr).Msg("Registering health server")

	healthpb.RegisterHealthServer(s.srv, s.healthCheck)
	s.healthRegistered = true

	return nil
}

// WithServerOptions adds gRPC server options.
func WithServerOptions(opt ...grpc.ServerOption) ServerOption {
	return func(s *Server) {
		s.serverOpts = append(s.serverOpts, opt...)
	}
}

// TelemetryFilter allows callers to suppress traces for matching RPCs.
type TelemetryFilter func(*grpcstats.RPCTagInfo) bool

// WithTelemetryFilter configures a filter to determine which RPCs emit telemetry.
func WithTelemetryFilter(filter TelemetryFilter) ServerOption {
	return func(s *Server) {
		s.telemetryFilter = filter
	}
}

// WithTelemetryDisabled disables OpenTelemetry stats handling for the server.
func WithTelemetryDisabled() ServerOption {
	return func(s *Server) {
		s.telemetryDisabled = true
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
	// Register health service before starting if not already registered
	if !s.healthRegistered && s.healthCheck != nil {
		if err := s.RegisterHealthServer(); err != nil {
			s.logger.Warn().Err(err).Msg("Warning")
		}
	}

	lc := &net.ListenConfig{}
	lis, err := lc.Listen(context.Background(), "tcp", s.addr)
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}

	s.logger.Info().Str("addr", s.addr).Msg("gRPC server listening")

	if err := s.srv.Serve(lis); err != nil && !errors.Is(err, errServerStopped) {
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

	// Give some time for graceful shutdown
	stopped := make(chan struct{})

	go func() {
		s.srv.GracefulStop()
		close(stopped)
	}()

	select {
	case <-stopped:
		s.logger.Info().Msg("gRPC server stopped gracefully")
	case <-time.After(shutdownTimer):
		s.logger.Warn().Msg("gRPC server shutdown timed out, forcing stop")
		s.srv.Stop()
	}
}

// LoggingInterceptor logs RPC calls and injects a trace-aware logger into the context.
func LoggingInterceptor(log logger.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		start := time.Now()

		// Create a trace-aware logger for this request
		var requestLogger = log

		// Check if we can cast the logger to access its underlying zerolog instance
		if zlogger, ok := log.(interface {
			WithFields(map[string]interface{}) zerolog.Logger
		}); ok {
			// Check for an active span in the context
			span := trace.SpanFromContext(ctx)
			if span.SpanContext().IsValid() {
				// Create a new logger with trace information
				spanCtx := span.SpanContext()
				enhancedLogger := zlogger.WithFields(map[string]interface{}{
					"trace_id": spanCtx.TraceID().String(),
					"span_id":  spanCtx.SpanID().String(),
				})

				// Wrap the enhanced logger back into our logger interface
				requestLogger = &loggerWrapper{logger: enhancedLogger}
			}
		}

		// Inject the request-scoped logger back into the context.
		newCtx := context.WithValue(ctx, loggerKey{}, requestLogger)

		// Call the actual handler with the new, logger-enriched context.
		resp, err := handler(newCtx, req)

		// Use the trace-aware requestLogger to log the completion of the call.
		requestLogger.Debug().
			Str("method", info.FullMethod).
			Dur("duration", time.Since(start)).
			Err(err).
			Msg("gRPC call")

		return resp, err
	}
}

// loggerWrapper wraps a zerolog.Logger to implement the logger.Logger interface
type loggerWrapper struct {
	logger zerolog.Logger
}

func (l *loggerWrapper) Trace() *zerolog.Event { return l.logger.Trace() }

func (l *loggerWrapper) Debug() *zerolog.Event { return l.logger.Debug() }

func (l *loggerWrapper) Info() *zerolog.Event { return l.logger.Info() }

func (l *loggerWrapper) Warn() *zerolog.Event { return l.logger.Warn() }

func (l *loggerWrapper) Error() *zerolog.Event { return l.logger.Error() }

func (l *loggerWrapper) Fatal() *zerolog.Event { return l.logger.Fatal() }

func (l *loggerWrapper) Panic() *zerolog.Event { return l.logger.Panic() }

func (l *loggerWrapper) With() zerolog.Context { return l.logger.With() }

func (l *loggerWrapper) WithComponent(component string) zerolog.Logger {
	return l.logger.With().Str("component", component).Logger()
}

func (l *loggerWrapper) WithFields(fields map[string]interface{}) zerolog.Logger {
	ctx := l.logger.With()
	for key, value := range fields {
		ctx = ctx.Interface(key, value)
	}

	return ctx.Logger()
}
func (l *loggerWrapper) SetLevel(level zerolog.Level) {
	l.logger = l.logger.Level(level)
}

func (l *loggerWrapper) SetDebug(debug bool) {
	if debug {
		l.logger = l.logger.Level(zerolog.DebugLevel)
	} else {
		l.logger = l.logger.Level(zerolog.InfoLevel)
	}
}

// RecoveryInterceptor handles panics in RPC handlers.
func RecoveryInterceptor(log logger.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp interface{}, err error) {
		defer func() {
			if r := recover(); r != nil {
				log.Error().Str("method", info.FullMethod).Interface("panic", r).Msg("Recovered from panic")

				err = errInternalError
			}
		}()

		return handler(ctx, req)
	}
}

// FromContext retrieves the logger from the context.
// If no logger is found, it returns a no-op test logger to prevent nil panics.
func FromContext(ctx context.Context) logger.Logger {
	if l, ok := ctx.Value(loggerKey{}).(logger.Logger); ok {
		return l
	}

	// Fallback to a safe, non-nil logger that discards all output.
	return logger.NewTestLogger()
}
