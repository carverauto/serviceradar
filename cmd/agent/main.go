// cmd/agent/main.go
package main

import (
	"log"
	"net"

	"github.com/mfreeman451/homemon/pkg/agent"
	"github.com/mfreeman451/homemon/proto"
	"google.golang.org/grpc"
)

func main() {
	log.Printf("Starting homemon agent...")
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	// Create server with no pre-configured checkers
	// Checkers will be created on-demand based on poller requests
	server := grpc.NewServer()
	proto.RegisterAgentServiceServer(server, agent.NewServer())

	log.Printf("Agent server listening on :50051")
	if err := server.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
