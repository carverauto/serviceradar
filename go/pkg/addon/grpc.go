/*
 * Copyright 2026 Carver Automation Corporation.
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

package addon

import (
	"context"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	goplugin "github.com/hashicorp/go-plugin"
	"google.golang.org/grpc"
)

// GRPCPlugin adapts an Addon implementation to the go-plugin gRPC transport. The
// server side carries Impl; the client side leaves it nil and returns an Addon
// client from GRPCClient.
type GRPCPlugin struct {
	goplugin.NetRPCUnsupportedPlugin
	Impl Addon
}

var _ goplugin.GRPCPlugin = (*GRPCPlugin)(nil)

// GRPCServer registers the add-on implementation with the plugin's gRPC server.
func (p *GRPCPlugin) GRPCServer(_ *goplugin.GRPCBroker, s *grpc.Server) error {
	addonpb.RegisterAddonServiceServer(s, &grpcServer{impl: p.Impl})
	return nil
}

// GRPCClient returns an Addon backed by the plugin's gRPC client connection.
func (p *GRPCPlugin) GRPCClient(_ context.Context, _ *goplugin.GRPCBroker, c *grpc.ClientConn) (interface{}, error) {
	return &grpcClient{client: addonpb.NewAddonServiceClient(c)}, nil
}

// ServerPluginSet is the plugin set an add-on serves (used by the SDK).
func ServerPluginSet(impl Addon) goplugin.PluginSet {
	return goplugin.PluginSet{PluginName: &GRPCPlugin{Impl: impl}}
}

// ClientPluginSet is the plugin set the agent dispenses (used by the manager).
func ClientPluginSet() goplugin.PluginSet {
	return goplugin.PluginSet{PluginName: &GRPCPlugin{}}
}

// grpcServer adapts an Addon to the generated AddonServiceServer.
type grpcServer struct {
	addonpb.UnimplementedAddonServiceServer
	impl Addon
}

func (s *grpcServer) Info(ctx context.Context, _ *addonpb.InfoRequest) (*addonpb.InfoResponse, error) {
	info, err := s.impl.Info(ctx)
	if err != nil {
		return nil, err
	}
	return &addonpb.InfoResponse{
		Id:           info.ID,
		Version:      info.Version,
		Capabilities: info.Capabilities,
	}, nil
}

func (s *grpcServer) Configure(ctx context.Context, req *addonpb.ConfigureRequest) (*addonpb.ConfigureResponse, error) {
	res, err := s.impl.Configure(ctx, req.GetConfigJson())
	if err != nil {
		return nil, err
	}
	return &addonpb.ConfigureResponse{
		ConfigHash: res.ConfigHash,
		Accepted:   res.Accepted,
		Error:      res.Error,
	}, nil
}

func (s *grpcServer) Health(ctx context.Context, _ *addonpb.HealthRequest) (*addonpb.HealthResponse, error) {
	h, err := s.impl.Health(ctx)
	if err != nil {
		return nil, err
	}
	return &addonpb.HealthResponse{
		Status:            healthStatusToProto(h.Status),
		Version:           h.Version,
		DegradationReason: h.DegradationReason,
	}, nil
}

// grpcClient adapts the generated AddonServiceClient to the Addon interface.
type grpcClient struct {
	client addonpb.AddonServiceClient
}

var _ Addon = (*grpcClient)(nil)

func (c *grpcClient) Info(ctx context.Context) (Info, error) {
	resp, err := c.client.Info(ctx, &addonpb.InfoRequest{})
	if err != nil {
		return Info{}, err
	}
	return Info{
		ID:           resp.GetId(),
		Version:      resp.GetVersion(),
		Capabilities: resp.GetCapabilities(),
	}, nil
}

func (c *grpcClient) Configure(ctx context.Context, configJSON []byte) (ConfigureResult, error) {
	resp, err := c.client.Configure(ctx, &addonpb.ConfigureRequest{ConfigJson: configJSON})
	if err != nil {
		return ConfigureResult{}, err
	}
	return ConfigureResult{
		ConfigHash: resp.GetConfigHash(),
		Accepted:   resp.GetAccepted(),
		Error:      resp.GetError(),
	}, nil
}

func (c *grpcClient) Health(ctx context.Context) (Health, error) {
	resp, err := c.client.Health(ctx, &addonpb.HealthRequest{})
	if err != nil {
		return Health{}, err
	}
	return Health{
		Status:            healthStatusFromProto(resp.GetStatus()),
		Version:           resp.GetVersion(),
		DegradationReason: resp.GetDegradationReason(),
	}, nil
}
