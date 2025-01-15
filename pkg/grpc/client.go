package grpc

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health/grpc_health_v1"
)

const (
	defaultMaxRetries                 = 3
	retryInterceptorTimeoutDuration   = 100 * time.Millisecond
	retryInterceptorAttemptMultiplier = 100
)

// ClientOption allows customization of the client.
type ClientOption func(*ClientConn)

// ClientConn wraps a gRPC client connection with additional functionality.
type ClientConn struct {
	conn         *grpc.ClientConn
	healthClient grpc_health_v1.HealthClient
	addr         string
	maxRetries   int
	mu           sync.RWMutex
}

// NewClient creates a new gRPC client connection.
func NewClient(ctx context.Context, addr string, opts ...ClientOption) (*ClientConn, error) {
	dialOpts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithChainUnaryInterceptor(
			ClientLoggingInterceptor,
			RetryInterceptor,
		),
	}

	conn, err := grpc.DialContext(ctx, addr, dialOpts...)
	if err != nil {
		return nil, fmt.Errorf("failed to dial: %w", err)
	}

	c := &ClientConn{
		conn:       conn,
		addr:       addr,
		maxRetries: 3, // default value
	}

	// Apply custom options
	for _, opt := range opts {
		opt(c)
	}

	// Initialize health client
	c.healthClient = grpc_health_v1.NewHealthClient(conn)

	return c, nil
}

// WithMaxRetries sets the maximum number of retry attempts.
func WithMaxRetries(retries int) ClientOption {
	return func(c *ClientConn) {
		c.maxRetries = retries
	}
}

// GetConnection returns the underlying gRPC connection.
func (c *ClientConn) GetConnection() *grpc.ClientConn {
	return c.conn
}

// Close closes the client connection.
func (c *ClientConn) Close() error {
	return c.conn.Close()
}

// CheckHealth checks the health of a specific service.
func (c *ClientConn) CheckHealth(ctx context.Context, service string) (bool, error) {
	resp, err := c.healthClient.Check(ctx, &grpc_health_v1.HealthCheckRequest{
		Service: service,
	})
	if err != nil {
		return false, fmt.Errorf("health check failed: %w", err)
	}

	return resp.Status == grpc_health_v1.HealthCheckResponse_SERVING, nil
}

// ClientLoggingInterceptor logs client-side RPC calls.
func ClientLoggingInterceptor(
	ctx context.Context,
	method string, req,
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
			time.Sleep(time.Duration(attempt*retryInterceptorAttemptMultiplier) * time.Millisecond)

			continue
		}

		return nil
	}

	return fmt.Errorf("all retry attempts failed: %w", lastErr)
}
