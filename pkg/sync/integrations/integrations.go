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
	return &armis.ArmisIntegration{
		Config:     config,
		KvClient:   kvClient,
		GrpcConn:   grpcConn,
		ServerName: serverName,
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
		Config:     config,
		KvClient:   kvClient,
		GrpcConn:   grpcConn,
		ServerName: serverName,
	}
}
