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

// Package integrations pkg/sync/integrations/integrations.go
package integrations

import (
	"context"
	"strconv"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client.
func NewArmisIntegration(
	_ context.Context,
	config models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *armis.ArmisIntegration {
	// Extract boundary name if specified in config
	boundaryName := ""
	if val, ok := config.Credentials["boundary"]; ok {
		boundaryName = val
	}

	// Extract page size if specified
	pageSize := 100 // default
	if val, ok := config.Credentials["page_size"]; ok {
		if size, err := strconv.Atoi(val); err == nil && size > 0 {
			pageSize = size
		}
	}

	return &armis.ArmisIntegration{
		Config:       config,
		KvClient:     kvClient,
		GrpcConn:     grpcConn,
		ServerName:   serverName,
		BoundaryName: boundaryName,
		PageSize:     pageSize,
	}
}

// NewNetboxIntegration creates a new NetboxIntegration instance.
func NewNetboxIntegration(
	_ context.Context,
	config models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *netbox.NetboxIntegration {
	return &netbox.NetboxIntegration{
		Config:        config,
		KvClient:      kvClient,
		GrpcConn:      grpcConn,
		ServerName:    serverName,
		ExpandSubnets: false, // Default: treat as /32 //TODO: make this configurable
	}
}
