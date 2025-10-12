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

// Package agent pkg/agent/registry.go
package agent

import (
	"context"
	"errors"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrDetailsRequiredMapperDiscovery indicates details field is required for mapper_discovery checks
	ErrDetailsRequiredMapperDiscovery = errors.New("details field is required for mapper_discovery checks")
)

// initRegistry creates a registry with logger support for agent package checkers
func initRegistry(log logger.Logger) checker.Registry {
	registry := checker.NewRegistry()

	// Register the process checker
	registry.Register("process",
		func(_ context.Context, serviceName, details string, _ *models.SecurityConfig) (checker.Checker, error) {
			if details == "" {
				details = serviceName // Fallback to service name if details empty
			}

			return &ProcessChecker{ProcessName: details, logger: log}, nil
		})

	// Register the port checker
	registry.Register("port",
		func(_ context.Context, _, details string, _ *models.SecurityConfig) (checker.Checker, error) {
			return NewPortChecker(details, log)
		})

	// Register the ICMP checker
	registry.Register("icmp",
		func(_ context.Context, _, details string, _ *models.SecurityConfig) (checker.Checker, error) {
			host := details
			if host == "" {
				host = "127.0.0.1"
			}

			return NewICMPChecker(host, log)
		})

	// Register the gRPC checker with logger support
	registry.Register("grpc",
		func(ctx context.Context, serviceName, details string, security *models.SecurityConfig) (checker.Checker, error) {
			if details == "" {
				return nil, errDetailsRequiredGRPC
			}

			// Determine the actual gRPC service name to use for health checks
			var actualGrpcServiceCheckName string

			switch serviceName {
			case "sysmon":
				actualGrpcServiceCheckName = defaultMonitoringServiceName
			case "sysmon-vm":
				actualGrpcServiceCheckName = defaultMonitoringServiceName
			case "mapper":
				// For mapper, we should use the monitoring.AgentService
				// but the CheckHealth method needs to be modified to handle this
				actualGrpcServiceCheckName = defaultMonitoringServiceName
			case "rperf-checker":
				actualGrpcServiceCheckName = defaultMonitoringServiceName
			case "sync":
				actualGrpcServiceCheckName = defaultMonitoringServiceName
			default:
				// For other services, use the standard health check
				actualGrpcServiceCheckName = "" // Empty string means use standard gRPC health
			}

			return NewExternalChecker(ctx, serviceName, "grpc", details, actualGrpcServiceCheckName, security, log)
		})

	// Register the SNMP checker with logger support
	registry.Register("snmp", func(ctx context.Context, _, details string, security *models.SecurityConfig) (checker.Checker, error) {
		if details == "" {
			return nil, errDetailsRequiredSNMP
		}

		return NewSNMPChecker(ctx, details, security, log)
	})

	// Register the mapper_discovery checker with logger support
	registry.Register("mapper_discovery",
		func(ctx context.Context, _, details string, security *models.SecurityConfig) (checker.Checker, error) {
			if details == "" {
				return nil, ErrDetailsRequiredMapperDiscovery
			}

			return NewMapperDiscoveryChecker(ctx, details, security, log)
		})

	return registry
}
