package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"time"

	"github.com/mfreeman451/homemon/pkg/cloud"
	"github.com/mfreeman451/homemon/pkg/cloud/api"
	"github.com/mfreeman451/homemon/proto"
	"google.golang.org/grpc"
)

// cmd/cloud/main.go

type Config struct {
	ListenAddr     string        `json:"listen_addr"`
	AlertThreshold time.Duration `json:"alert_threshold"`
}

func (c *Config) UnmarshalJSON(data []byte) error {
	type Alias Config
	aux := &struct {
		AlertThreshold string `json:"alert_threshold"`
		*Alias
	}{
		Alias: (*Alias)(c),
	}

	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}

	// Parse the alert threshold
	if aux.AlertThreshold != "" {
		duration, err := time.ParseDuration(aux.AlertThreshold)
		if err != nil {
			return fmt.Errorf("invalid alert threshold format: %w", err)
		}
		c.AlertThreshold = duration
	}

	return nil
}

func loadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("failed to read config: %w", err)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return Config{}, fmt.Errorf("failed to parse config: %w", err)
	}

	return config, nil
}

func main() {
	configPath := flag.String("config", "/etc/homemon/cloud.json", "Path to config file")
	flag.Parse()

	config, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Create and start API server
	apiServer := api.NewAPIServer()

	alertFunc := func(pollerID string, duration time.Duration) {
		log.Printf("Alert: Poller %s hasn't reported in %v", pollerID, duration)
	}

	server := grpc.NewServer()
	cloudServer := cloud.NewServer(config.AlertThreshold, alertFunc)
	cloudServer.SetAPIServer(apiServer)
	proto.RegisterPollerServiceServer(server, cloudServer)

	// Start HTTP server for API and web interface
	go func() {
		log.Printf("Starting HTTP server on %s", config.ListenAddr)
		if err := apiServer.Start(config.ListenAddr); err != nil {
			log.Fatalf("HTTP server failed: %v", err)
		}
	}()

	// Start gRPC server
	lis, err := net.Listen("tcp", ":50052")
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	log.Printf("gRPC server listening on :50052")
	if err := server.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}
