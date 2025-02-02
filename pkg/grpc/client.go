// Package grpc - gRPC client with mTLS support
package grpc

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"
)

const (
	defaultMaxRetries                 = 3
	retryInterceptorTimeoutDuration   = 100 * time.Millisecond
	retryInterceptorAttemptMultiplier = 100
	grpcKeepAliveTime                 = 10 * time.Second
	grpcKeepAliveTimeout              = 5 * time.Second
)

// ClientOption allows customization of the client.
type ClientOption func(*ClientConn)

// ClientConn wraps a gRPC client connection with additional functionality.
type ClientConn struct {
	conn              *grpc.ClientConn
	healthClient      grpc_health_v1.HealthClient
	addr              string
	maxRetries        int
	mu                sync.RWMutex
	lastHealthDetails string
	lastHealthCheck   time.Time
	securityProvider  SecurityProvider
}

// NewClient creates a new gRPC client connection.
func NewClient(ctx context.Context, addr string, opts ...ClientOption) (*ClientConn, error) {
	c := &ClientConn{
		addr:       addr,
		maxRetries: defaultMaxRetries,
	}

	// Apply custom options
	for _, opt := range opts {
		opt(c)
	}
	// Default to NoSecurityProvider if none is specified
	if c.securityProvider == nil {
		c.securityProvider = &NoSecurityProvider{}
	}

	dialOpts, err := c.createDialOptions(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to create dial options: %w", err)
	}

	conn, err := grpc.DialContext(ctx, addr, dialOpts...) //nolint:staticcheck // ignore warning for DialContext
	if err != nil {
		return nil, fmt.Errorf("failed to dial: %w", err)
	}

	c.conn = conn

	// Initialize health client
	c.healthClient = grpc_health_v1.NewHealthClient(conn)

	return c, nil
}

func (c *ClientConn) createDialOptions(ctx context.Context) ([]grpc.DialOption, error) {
	creds, err := c.securityProvider.GetClientCredentials(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get client credentials: %w", err)
	}

	dialOpts := []grpc.DialOption{
		creds,
		grpc.WithChainUnaryInterceptor(
			ClientLoggingInterceptor,
			RetryInterceptor,
		),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                grpcKeepAliveTime,
			Timeout:             grpcKeepAliveTimeout,
			PermitWithoutStream: true,
		}),
	}

	return dialOpts, nil
}

// WithMaxRetries sets the maximum number of retry attempts.
func WithMaxRetries(retries int) ClientOption {
	return func(c *ClientConn) {
		c.maxRetries = retries
	}
}

// WithSecurityProvider sets the security provider for the client.
func WithSecurityProvider(provider SecurityProvider) ClientOption {
	return func(c *ClientConn) {
		c.securityProvider = provider
	}
}

// GetConnection returns the underlying gRPC connection.
func (c *ClientConn) GetConnection() *grpc.ClientConn {
	return c.conn
}

// Close closes the client connection.
func (c *ClientConn) Close() error {
	if c.securityProvider != nil {
		if err := c.securityProvider.Close(); err != nil {
			log.Printf("Failed to close security provider: %v", err)
		}
	}

	return c.conn.Close()
}

// CheckHealth checks the health of a specific service.
func (c *ClientConn) CheckHealth(ctx context.Context, service string) (bool, error) {
	var header metadata.MD

	resp, err := c.healthClient.Check(ctx, &grpc_health_v1.HealthCheckRequest{
		Service: service,
	}, grpc.Header(&header))
	if err != nil {
		return false, fmt.Errorf("health check failed: %w", err)
	}

	return resp.Status == grpc_health_v1.HealthCheckResponse_SERVING, nil
}

// GetHealthDetails returns the last known health details.
func (c *ClientConn) GetHealthDetails() string {
	c.mu.RLock()
	defer c.mu.RUnlock()

	return c.lastHealthDetails
}

// GetLastHealthCheck returns the timestamp of the last successful health check.
func (c *ClientConn) GetLastHealthCheck() time.Time {
	c.mu.RLock()
	defer c.mu.RUnlock()

	return c.lastHealthCheck
}

// ClientLoggingInterceptor logs client-side RPC calls.
func ClientLoggingInterceptor(
	ctx context.Context,
	method string,
	req interface{},
	reply interface{},
	cc *grpc.ClientConn,
	invoker grpc.UnaryInvoker,
	opts ...grpc.CallOption) error {
	start := time.Now()
	err := invoker(ctx, method, req, reply, cc, opts...)
	log.Printf("gRPC client call: %s Duration: %v Error: %v",
		method,
		time.Since(start),
		err)

	return err
}

// RetryInterceptor implements retry logic for failed calls.
func RetryInterceptor(ctx context.Context,
	method string,
	req, reply interface{},
	cc *grpc.ClientConn,
	invoker grpc.UnaryInvoker,
	opts ...grpc.CallOption) error {
	var lastErr error

	for attempt := 0; attempt < defaultMaxRetries; attempt++ {
		if err := invoker(ctx, method, req, reply, cc, opts...); err != nil {
			lastErr = err
			log.Printf("gRPC call attempt %d failed: %v", attempt+1, err)
			time.Sleep(time.Duration(attempt*retryInterceptorAttemptMultiplier) * retryInterceptorTimeoutDuration)

			continue
		}

		return nil
	}

	return fmt.Errorf("all retry attempts failed: %w", lastErr)
}
