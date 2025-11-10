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

package api

import (
	"context"
	"errors"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/proto"
)

// templateRegistryGetter wraps the core template registry gRPC interface
// and provides a simpler API for the API server.
type templateRegistryGetter interface {
	GetTemplate(ctx context.Context, req *proto.GetTemplateRequest) (*proto.GetTemplateResponse, error)
}

// templateRegistryAdapter adapts the gRPC template registry interface
// to the API package's TemplateRegistry interface.
type templateRegistryAdapter struct {
	getter templateRegistryGetter
}

// NewTemplateRegistryAdapter creates an adapter for the template registry.
func NewTemplateRegistryAdapter(getter templateRegistryGetter) TemplateRegistry {
	return &templateRegistryAdapter{getter: getter}
}

var errTemplateMissing = errors.New("template not found")

// Get retrieves a template from the registry.
func (a *templateRegistryAdapter) Get(serviceName string) ([]byte, config.ConfigFormat, error) {
	resp, err := a.getter.GetTemplate(context.Background(), &proto.GetTemplateRequest{
		ServiceName: serviceName,
	})
	if err != nil {
		return nil, "", fmt.Errorf("failed to get template for %s: %w", serviceName, err)
	}

	if !resp.Found {
		return nil, "", fmt.Errorf("%w: %s", errTemplateMissing, serviceName)
	}

	return resp.TemplateData, config.ConfigFormat(resp.Format), nil
}
