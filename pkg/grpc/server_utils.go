package grpc

import (
	"log"

	"google.golang.org/grpc"
)

type RegisterFn func(s *grpc.Server)

// StartGRPCServer starts a gRPC server on `listenAddr` and calls each
// provided registerFn to register gRPC services.
func StartGRPCServer(listenAddr string, opts []ServerOption, registerFns ...RegisterFn) (*Server, error) {
	srv := NewServer(listenAddr, opts...)

	// Register each service
	for _, fn := range registerFns {
		fn(srv.GetGRPCServer())
	}

	// Start listening in background
	go func() {
		if err := srv.Start(); err != nil {
			log.Printf("gRPC server error: %v", err)
		}
	}()

	return srv, nil
}
