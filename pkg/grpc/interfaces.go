package grpc

import (
	"context"

	"google.golang.org/grpc"
)

//go:generate mockgen -destination=mock_grpc.go -package=grpc github.com/mfreeman451/serviceradar/pkg/grpc SecurityProvider

// SecurityProvider defines the interface for gRPC security providers
type SecurityProvider interface {
	// GetClientCredentials returns credentials for client connections
	GetClientCredentials(ctx context.Context) (grpc.DialOption, error)

	// GetServerCredentials returns credentials for server connections
	GetServerCredentials(ctx context.Context) (grpc.ServerOption, error)

	// Close cleans up any resources
	Close() error
}
