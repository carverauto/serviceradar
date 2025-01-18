// Package agent pkg/agent/external_checker.go
package agent

import (
	"context"
	"fmt"
	"log"

	grpcpkg "github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/proto"
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
	serviceName string // Name of the service (e.g., "dusk")
	serviceType string // Type of service (e.g., "grpc")
	address     string
	client      *grpcpkg.ClientConn
}

// NewExternalChecker creates a new checker that connects to an external process.
func NewExternalChecker(ctx context.Context, serviceName, serviceType, address string) (*ExternalChecker, error) {
	log.Printf("Creating new external checker name=%s type=%s at %s", serviceName, serviceType, address)

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
		serviceName: serviceName,
		serviceType: serviceType,
		address:     address,
		client:      client,
	}

	// Initial health check
	healthy, err := client.CheckHealth(context.Background(), "")
	if err != nil {
		if closeErr := client.Close(); closeErr != nil {
			return nil, closeErr
		}

		return nil, fmt.Errorf("extChecker: %w, err: %w", errHealth, err)
	}

	if !healthy {
		if err := client.Close(); err != nil {
			return nil, err
		}

		return nil, errServiceHealth
	}

	log.Printf("Successfully created external checker name=%s type=%s", serviceName, serviceType)

	return checker, nil
}

func (e *ExternalChecker) Check(ctx context.Context) (isAccessible bool, statusMsg string) {
	// First check basic health
	healthy, err := e.client.CheckHealth(ctx, "")
	if err != nil {
		log.Printf("External checker %s: Health check failed: %v", e.serviceName, err)

		return false, fmt.Sprintf("Failed to check %s: %v", e.serviceName, err)
	}

	if !healthy {
		log.Printf("External checker %s: Service reported unhealthy", e.serviceName)

		return false, fmt.Sprintf("%s is not healthy", e.serviceName)
	}

	// Then get block details through AgentService
	client := proto.NewAgentServiceClient(e.client.GetConnection())

	status, err := client.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: e.serviceName,
		ServiceType: e.serviceType,
	})
	if err != nil {
		log.Printf("External checker %s: Failed to get details: %v", e.serviceName, err)

		return true, fmt.Sprintf("%s is healthy but details unavailable", e.serviceName)
	}

	log.Printf("External checker %s: Received status message: %s", e.serviceName, status.Message)

	return true, status.Message
}

// Close cleans up the checker's resources.
func (e *ExternalChecker) Close() error {
	if e.client != nil {
		return e.client.Close()
	}

	return nil
}
