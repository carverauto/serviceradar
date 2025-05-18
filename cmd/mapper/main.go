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
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/mapper"
	monitoringpb "github.com/carverauto/serviceradar/proto"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"

	googlegrpc "google.golang.org/grpc"
)

// cliAppConfig holds the command-line configuration options.
type cliAppConfig struct {
	configFile string
	listenAddr string
}

// parseFlags parses command-line flags and returns a cliAppConfig.
func parseFlags() cliAppConfig {
	cfg := cliAppConfig{}
	flag.StringVar(&cfg.configFile, "config", "/etc/serviceradar/mapper.json", "Path to mapper config file")
	flag.StringVar(&cfg.listenAddr, "listen", ":50056", "Address for mapper to listen on")
	flag.Parse()

	return cfg
}

func main() {
	appCfg := parseFlags()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		log.Printf("Received signal %v, initiating shutdown for ServiceRadar Mapper", sig)

		cancel()
	}()

	log.Printf("Starting ServiceRadar Mapper Service...")

	configLoader := config.NewConfig()

	var discoveryEngineConfig mapper.Config

	if appCfg.configFile == "" {
		log.Printf("Mapper configuration file must be specified using the -config flag.")
		return
	}

	if err := configLoader.LoadAndValidate(ctx, appCfg.configFile, &discoveryEngineConfig); err != nil {
		log.Printf("Failed to load mapper configuration: %v", err)
		return
	}

	var publisher mapper.Publisher

	engine, err := mapper.NewSnmpDiscoveryEngine(&discoveryEngineConfig, publisher)
	if err != nil {
		log.Printf("Failed to initialize discovery engine: %v", err)
		return
	}

	grpcDiscoveryService := mapper.NewGRPCDiscoveryService(engine)

	snmpEngine, ok := engine.(*mapper.SNMPDiscoveryEngine)
	if !ok {
		log.Printf("Failed to cast discovery engine to *mapper.SNMPDiscoveryEngine for health service")
		return
	}

	grpcMapperAgentService := mapper.NewMapperAgentService(snmpEngine)

	serverOptions := &lifecycle.ServerOptions{
		ListenAddr:  appCfg.listenAddr,
		ServiceName: "serviceradar-mapper",
		Service:     engine,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(server *googlegrpc.Server) error {
				discoverypb.RegisterDiscoveryServiceServer(server, grpcDiscoveryService)
				monitoringpb.RegisterAgentServiceServer(server, grpcMapperAgentService)

				return nil
			},
		},
		EnableHealthCheck: true,
		Security:          discoveryEngineConfig.Security,
	}

	log.Printf("ServiceRadar Mapper gRPC server starting on %s", appCfg.listenAddr)

	if err := lifecycle.RunServer(ctx, serverOptions); err != nil {
		log.Printf("ServiceRadar Mapper server error: %v", err)
	}

	log.Println("ServiceRadar Mapper stopped")
}
