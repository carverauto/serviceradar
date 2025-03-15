/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc" // For the underlying gRPC server type
)

const (
	defaultSNMPStopTimeout = 10 * time.Second
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	log.Printf("Starting SNMP checker...")

	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/checkers/snmp.json", "Path to config file")
	flag.Parse()

	// Load and validate configuration using shared config package
	var cfg snmp.Config

	if err := config.LoadAndValidate(*configPath, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
	}

	// Create SNMP service
	service, err := snmp.NewSNMPService(&cfg)
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	// Create and register block service
	snmpAgentService := snmp.NewSNMPPollerService(&snmp.Poller{Config: cfg}, service)

	// Create gRPC service registrar
	registerServices := func(s *grpc.Server) error { // s is *google.golang.org/grpc.Server due to lifecycle update
		proto.RegisterAgentServiceServer(s, snmpAgentService)

		return nil
	}

	// Create and configure service options
	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              &snmpService{service: service},
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	}

	// Run service with lifecycle management
	if err := lifecycle.RunServer(context.Background(), &opts); err != nil {
		return fmt.Errorf("server error: %w", err)
	}

	return nil
}

// snmpService wraps the SNMPService to implement lifecycle.Service.
type snmpService struct {
	service *snmp.SNMPService
}

func (s *snmpService) Start(ctx context.Context) error {
	log.Printf("Starting SNMP service...")

	return s.service.Start(ctx)
}

func (s *snmpService) Stop(ctx context.Context) error {
	log.Printf("Stopping SNMP service...")

	_, cancel := context.WithTimeout(ctx, defaultSNMPStopTimeout)
	defer cancel()

	return s.service.Stop()
}
