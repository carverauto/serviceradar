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
)

// ClientConfig holds configuration for the gRPC client
type ClientConfig struct {
	Address          string
	SecurityProvider SecurityProvider
	MaxRetries       int
}

// Client manages a gRPC client connection
type Client struct {
	conn   *grpc.ClientConn
	health grpc_health_v1.HealthClient
	config ClientConfig
	mu     sync.RWMutex
	closed bool
}

// NewClient creates a new gRPC client
func NewClient(ctx context.Context, cfg ClientConfig) (*Client, error) {
	if cfg.Address == "" {
		return nil, fmt.Errorf("address is required")
	}

	// Default to no security if none provided
	if cfg.SecurityProvider == nil {
		cfg.SecurityProvider = &NoSecurityProvider{}
	}
	if cfg.MaxRetries == 0 {
		cfg.MaxRetries = 3
	}

	dialOpts, err := createDialOptions(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create dial options: %w", err)
	}

	conn, err := grpc.NewClient(cfg.Address, dialOpts...)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to %s: %w", cfg.Address, err)
	}

	return &Client{
		conn:   conn,
		health: grpc_health_v1.NewHealthClient(conn),
		config: cfg,
	}, nil
}

func createDialOptions(ctx context.Context, cfg ClientConfig) ([]grpc.DialOption, error) {
	creds, err := cfg.SecurityProvider.GetClientCredentials(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get client credentials: %w", err)
	}

	return []grpc.DialOption{
		creds,
		grpc.WithUnaryInterceptor(RetryInterceptor(cfg.MaxRetries)),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                120 * time.Second, // Match server
			Timeout:             20 * time.Second,
			PermitWithoutStream: false,
		}),
	}, nil
}

// GetConnection returns the underlying gRPC connection
func (c *Client) GetConnection() *grpc.ClientConn {
	return c.conn
}

// CheckHealth performs a health check on the specified service
func (c *Client) CheckHealth(ctx context.Context, service string) (bool, error) {
	resp, err := c.health.Check(ctx, &grpc_health_v1.HealthCheckRequest{Service: service})
	if err != nil {
		return false, fmt.Errorf("health check failed: %w", err)
	}
	return resp.Status == grpc_health_v1.HealthCheckResponse_SERVING, nil
}

// Close shuts down the client connection
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return nil
	}

	c.closed = true
	if c.config.SecurityProvider != nil {
		if err := c.config.SecurityProvider.Close(); err != nil {
			log.Printf("Failed to close security provider: %v", err)
		}
	}
	return c.conn.Close()
}

// RetryInterceptor provides basic retry logic
func RetryInterceptor(maxRetries int) grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		var lastErr error
		backoff := 1 * time.Second

		for attempt := 0; attempt < maxRetries; attempt++ {
			start := time.Now()
			err := invoker(ctx, method, req, reply, cc, opts...)
			log.Printf("gRPC call: %s attempt: %d duration: %v error: %v",
				method, attempt+1, time.Since(start), err)

			if err == nil {
				return nil
			}

			lastErr = err
			if attempt == maxRetries-1 {
				break
			}

			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(backoff):
				backoff *= 2
				if backoff > 30*time.Second {
					backoff = 30 * time.Second
				}
			}
		}
		return fmt.Errorf("all %d retries failed: %w", maxRetries, lastErr)
	}
}
