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

	"github.com/carverauto/serviceradar/pkg/checker"
)

func initRegistry() checker.Registry {
	registry := checker.NewRegistry()

	// Register the process checker
	registry.Register("process", func(_ context.Context, serviceName, details string) (checker.Checker, error) {
		if details == "" {
			details = serviceName // Fallback to service name if details empty
		}

		return &ProcessChecker{ProcessName: details}, nil
	})

	// Register the port checker
	registry.Register("port", func(_ context.Context, _, details string) (checker.Checker, error) {
		return NewPortChecker(details)
	})

	// Register the ICMP checker
	registry.Register("icmp", func(_ context.Context, _, details string) (checker.Checker, error) {
		host := details
		if host == "" {
			host = "127.0.0.1"
		}
		return NewICMPChecker(host)
	})

	// Register the gRPC checker
	registry.Register("grpc", func(ctx context.Context, serviceName, details string) (checker.Checker, error) {
		if details == "" {
			return nil, errDetailsRequiredGRPC
		}

		return NewExternalChecker(ctx, serviceName, "grpc", details)
	})

	// Register the SNMP checker
	registry.Register("snmp", func(ctx context.Context, _, details string) (checker.Checker, error) {
		if details == "" {
			return nil, errDetailsRequiredSNMP
		}

		return NewSNMPChecker(ctx, details)
	})

	return registry
}
