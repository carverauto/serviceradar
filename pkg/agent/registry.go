// Package agent pkg/agent/registry.go
package agent

import (
	"context"
	"fmt"

	"github.com/mfreeman451/serviceradar/pkg/checker"
)

func initRegistry() checker.Registry {
	registry := checker.NewRegistry()

	// Register the process checker
	registry.Register("process", func(ctx context.Context, serviceName, details string) (checker.Checker, error) {
		if details == "" {
			details = serviceName // Fallback to service name if details empty
		}

		return &ProcessChecker{ProcessName: details}, nil
	})

	// Register the port checker
	registry.Register("port", func(ctx context.Context, serviceName, details string) (checker.Checker, error) {
		return NewPortChecker(details)
	})

	// Register the ICMP checker
	registry.Register("icmp", func(ctx context.Context, serviceName, details string) (checker.Checker, error) {
		host := details
		if host == "" {
			host = "127.0.0.1" // Default to localhost if no host specified
		}

		return &ICMPChecker{
			Host:  host,
			Count: 3, // Default ICMP count
		}, nil
	})

	// Register the gRPC checker
	registry.Register("grpc", func(ctx context.Context, serviceName, details string) (checker.Checker, error) {
		if details == "" {
			return nil, fmt.Errorf("details field is required for gRPC checks")
		}

		return NewExternalChecker(ctx, serviceName, "grpc", details)
	})

	return registry
}
