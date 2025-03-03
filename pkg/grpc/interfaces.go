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

package grpc

import (
	"context"

	"google.golang.org/grpc"
)

//go:generate mockgen -destination=mock_grpc.go -package=grpc github.com/carverauto/serviceradar/pkg/grpc SecurityProvider

// SecurityProvider defines the interface for gRPC security providers.
type SecurityProvider interface {
	// GetClientCredentials returns credentials for client connections
	GetClientCredentials(ctx context.Context) (grpc.DialOption, error)

	// GetServerCredentials returns credentials for server connections
	GetServerCredentials(ctx context.Context) (grpc.ServerOption, error)

	// Close cleans up any resources
	Close() error
}
