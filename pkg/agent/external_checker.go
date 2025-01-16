// Package agent pkg/agent/external_checker.go
package agent

import (
	"context"
	"fmt"
	"log"

	grpcpkg "github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"
)

const (
	maxRetries = 3
)

var (
	errHealth        = fmt.Errorf("service is not healthy")
	errServiceHealth = fmt.Errorf("service is not healthy")
)

// ExternalChecker implements checker.Checker for external checker processes.
type ExternalChecker struct {
	name    string
	address string
	client  *grpcpkg.ClientConn
}

// NewExternalChecker creates a new checker that connects to an external process.
func NewExternalChecker(ctx context.Context, name, address string) (*ExternalChecker, error) {
	log.Printf("Creating new external checker %s at %s", name, address)

	// Create client using our gRPC package
	client, err := grpcpkg.NewClient(
		ctx,
		address,
		grpcpkg.WithMaxRetries(maxRetries),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create gRPC client: %w", err)
	}

	checker := &ExternalChecker{
		name:    name,
		address: address,
		client:  client,
	}

	// Initial health check
	healthy, err := client.CheckHealth(context.Background(), "")
	if err != nil {
		err := client.Close()
		if err != nil {
			return nil, err
		}

		return nil, fmt.Errorf("extChecker: %w, err: %w", errHealth, err)
	}

	if !healthy {
		err := client.Close()
		if err != nil {
			return nil, err
		}

		return nil, errServiceHealth
	}

	log.Printf("Successfully created external checker %s", name)

	return checker, nil
}

func (e *ExternalChecker) Check(ctx context.Context) (bool, string) {
	// First check basic health
	healthy, err := e.client.CheckHealth(ctx, "")
	if err != nil {
		log.Printf("External checker %s: Health check failed: %v", e.name, err)
		return false, fmt.Sprintf("Failed to check %s: %v", e.name, err)
	}

	if !healthy {
		log.Printf("External checker %s: Service reported unhealthy", e.name)
		return false, fmt.Sprintf("%s is not healthy", e.name)
	}

	// Then get block details through AgentService
	client := proto.NewAgentServiceClient(e.client.GetConnection())
	status, err := client.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: "dusk",
	})
	if err != nil {
		log.Printf("External checker %s: Failed to get block details: %v", e.name, err)
		return true, fmt.Sprintf("%s is healthy but block details unavailable", e.name)
	}

	log.Printf("External checker %s: Received status message: %s", e.name, status.Message)
	return true, status.Message
}

// Close cleans up the checker's resources.
func (e *ExternalChecker) Close() error {
	if e.client != nil {
		return e.client.Close()
	}

	return nil
}
