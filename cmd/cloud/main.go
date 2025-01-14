package main

import (
	"context"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mfreeman451/homemon/pkg/cloud"
	"github.com/mfreeman451/homemon/pkg/cloud/api"
	"github.com/mfreeman451/homemon/proto"
	"google.golang.org/grpc"
)

func main() {
	lis, err := net.Listen("tcp", ":50052")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	alertFunc := func(pollerID string, duration time.Duration) {
		log.Printf("Alert: Poller %s hasn't reported in %v", pollerID, duration)
		// Implement your alerting logic here
	}

	server := grpc.NewServer()
	cloudServer := cloud.NewServer(5*time.Minute, alertFunc)
	proto.RegisterPollerServiceServer(server, cloudServer)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		cancel()
		server.GracefulStop()
	}()

	// Create and start API server
	apiServer := api.NewAPIServer()
	go func() {
		if err := apiServer.Start(":8090"); err != nil {
			log.Printf("API server error: %v", err)
		}
	}()

	// Modify cloud server to update API status
	cloudServer.SetAPIServer(apiServer)

	go cloudServer.MonitorPollers(ctx)

	log.Printf("☁️Cloud server listening on :50052")
	if err := server.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
