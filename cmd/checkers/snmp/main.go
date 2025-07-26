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
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc" // For the underlying gRPC server type
)

const (
	defaultSNMPStopTimeout = 10 * time.Second
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

// loggerWrapper wraps zerolog.Logger to implement logger.Logger interface
type loggerWrapper struct {
	logger zerolog.Logger
}

func (l *loggerWrapper) Debug() *zerolog.Event { return l.logger.Debug() }
func (l *loggerWrapper) Info() *zerolog.Event  { return l.logger.Info() }
func (l *loggerWrapper) Warn() *zerolog.Event  { return l.logger.Warn() }
func (l *loggerWrapper) Error() *zerolog.Event { return l.logger.Error() }
func (l *loggerWrapper) Fatal() *zerolog.Event { return l.logger.Fatal() }
func (l *loggerWrapper) Panic() *zerolog.Event { return l.logger.Panic() }
func (l *loggerWrapper) With() zerolog.Context { return l.logger.With() }
func (l *loggerWrapper) WithComponent(component string) zerolog.Logger {
	return l.logger.With().Str("component", component).Logger()
}
func (l *loggerWrapper) WithFields(fields map[string]interface{}) zerolog.Logger {
	return l.logger.With().Fields(fields).Logger()
}
func (l *loggerWrapper) SetLevel(level zerolog.Level) { l.logger = l.logger.Level(level) }
func (l *loggerWrapper) SetDebug(debug bool) {
	if debug {
		l.SetLevel(zerolog.DebugLevel)
	} else {
		l.SetLevel(zerolog.InfoLevel)
	}
}

func main() {
	if err := run(); err != nil {
		logger.Fatal().Err(err).Msg("Fatal error")
	}
}

func run() error {
	logger.Info().Msg("Starting SNMP checker")

	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/checkers/snmp.json", "Path to config file")
	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Initialize configuration loader
	cfgLoader := config.NewConfig(nil)

	// Load configuration with context
	var cfg snmp.SNMPConfig

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
	}

	// Create logger wrapper
	log := &loggerWrapper{logger: logger.GetLogger()}

	// Create SNMP service
	service, err := snmp.NewSNMPService(&cfg, log)
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	// Create and register block service
	snmpAgentService := snmp.NewSNMPPollerService(&snmp.Poller{Config: cfg}, service, log)

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
	if err := lifecycle.RunServer(ctx, &opts); err != nil {
		return fmt.Errorf("server error: %w", err)
	}

	return nil
}

// snmpService wraps the SNMPService to implement lifecycle.Service.
type snmpService struct {
	service *snmp.SNMPService
}

func (s *snmpService) Start(ctx context.Context) error {
	logger.Info().Msg("Starting SNMP service")

	return s.service.Start(ctx)
}

func (s *snmpService) Stop(ctx context.Context) error {
	logger.Info().Msg("Stopping SNMP service")

	_, cancel := context.WithTimeout(ctx, defaultSNMPStopTimeout)
	defer cancel()

	return s.service.Stop()
}
