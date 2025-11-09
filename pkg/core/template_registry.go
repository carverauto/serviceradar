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

package core

import (
	"context"

	"github.com/carverauto/serviceradar/proto"
)

// templateRegistry defines the interface for service template management.
// This allows for mocking in tests while keeping the actual registry implementation private.
type templateRegistry interface {
	RegisterTemplate(ctx context.Context, req *proto.RegisterTemplateRequest) (*proto.RegisterTemplateResponse, error)
	GetTemplate(ctx context.Context, req *proto.GetTemplateRequest) (*proto.GetTemplateResponse, error)
	ListTemplates(ctx context.Context, req *proto.ListTemplatesRequest) (*proto.ListTemplatesResponse, error)
}

// RegisterTemplate implements the CoreService gRPC method by delegating to the template registry.
func (s *Server) RegisterTemplate(ctx context.Context, req *proto.RegisterTemplateRequest) (*proto.RegisterTemplateResponse, error) {
	return s.templateRegistry.RegisterTemplate(ctx, req)
}

// GetTemplate implements the CoreService gRPC method by delegating to the template registry.
func (s *Server) GetTemplate(ctx context.Context, req *proto.GetTemplateRequest) (*proto.GetTemplateResponse, error) {
	return s.templateRegistry.GetTemplate(ctx, req)
}

// ListTemplates implements the CoreService gRPC method by delegating to the template registry.
func (s *Server) ListTemplates(ctx context.Context, req *proto.ListTemplatesRequest) (*proto.ListTemplatesResponse, error) {
	return s.templateRegistry.ListTemplates(ctx, req)
}

// TemplateRegistry returns the template registry for internal core use (e.g., admin API seeding).
func (s *Server) TemplateRegistry() templateRegistry {
	return s.templateRegistry
}
