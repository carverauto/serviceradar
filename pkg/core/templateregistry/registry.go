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
 * See OR the License for the specific language governing permissions and
 * limitations under the License.
 */

package templateregistry

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errServiceNameRequired = errors.New("service_name is required")
	errTemplateDataEmpty   = errors.New("template_data cannot be empty")
	errFormatInvalid       = errors.New("format must be 'json' or 'toml'")
	errTemplateNotFound    = errors.New("template not found")
)

// Template represents a registered service configuration template.
type Template struct {
	ServiceName    string
	Data           []byte
	Format         config.ConfigFormat
	ServiceVersion string
	RegisteredAt   time.Time
}

// Registry stores and manages service configuration templates.
// Services register their default configs on startup, making them available
// for admin-initiated seeding operations without embedding templates in core.
type Registry struct {
	mu        sync.RWMutex
	templates map[string]*Template
	logger    logger.Logger
}

// New creates a new template registry.
func New(log logger.Logger) *Registry {
	return &Registry{
		templates: make(map[string]*Template),
		logger:    log,
	}
}

// RegisterTemplate implements the gRPC RegisterTemplate RPC.
func (r *Registry) RegisterTemplate(ctx context.Context, req *proto.RegisterTemplateRequest) (*proto.RegisterTemplateResponse, error) {
	if err := r.validate(req); err != nil {
		return &proto.RegisterTemplateResponse{
			Success: false,
			Message: err.Error(),
		}, nil
	}

	format := config.ConfigFormat(strings.ToLower(req.Format))
	tmpl := &Template{
		ServiceName:    req.ServiceName,
		Data:           req.TemplateData,
		Format:         format,
		ServiceVersion: req.ServiceVersion,
		RegisteredAt:   time.Now(),
	}

	r.mu.Lock()
	r.templates[req.ServiceName] = tmpl
	r.mu.Unlock()

	r.logger.Info().
		Str("service", req.ServiceName).
		Str("format", string(format)).
		Str("version", req.ServiceVersion).
		Int("size_bytes", len(req.TemplateData)).
		Msg("registered service template")

	return &proto.RegisterTemplateResponse{
		Success: true,
		Message: fmt.Sprintf("template for %s registered successfully", req.ServiceName),
	}, nil
}

// GetTemplate implements the gRPC GetTemplate RPC.
func (r *Registry) GetTemplate(ctx context.Context, req *proto.GetTemplateRequest) (*proto.GetTemplateResponse, error) {
	if req.ServiceName == "" {
		return &proto.GetTemplateResponse{Found: false}, nil
	}

	r.mu.RLock()
	tmpl, found := r.templates[req.ServiceName]
	r.mu.RUnlock()

	if !found {
		return &proto.GetTemplateResponse{Found: false}, nil
	}

	return &proto.GetTemplateResponse{
		Found:          true,
		TemplateData:   tmpl.Data,
		Format:         string(tmpl.Format),
		ServiceVersion: tmpl.ServiceVersion,
		RegisteredAt:   tmpl.RegisteredAt.Unix(),
	}, nil
}

// ListTemplates implements the gRPC ListTemplates RPC.
func (r *Registry) ListTemplates(ctx context.Context, req *proto.ListTemplatesRequest) (*proto.ListTemplatesResponse, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	templates := make([]*proto.TemplateInfo, 0, len(r.templates))
	for name, tmpl := range r.templates {
		if req.Prefix != "" && !strings.HasPrefix(name, req.Prefix) {
			continue
		}

		templates = append(templates, &proto.TemplateInfo{
			ServiceName:    name,
			Format:         string(tmpl.Format),
			ServiceVersion: tmpl.ServiceVersion,
			RegisteredAt:   tmpl.RegisteredAt.Unix(),
			SizeBytes:      int32(len(tmpl.Data)),
		})
	}

	return &proto.ListTemplatesResponse{Templates: templates}, nil
}

// Get retrieves a template by service name (internal API for core components).
func (r *Registry) Get(serviceName string) (*Template, error) {
	if serviceName == "" {
		return nil, errServiceNameRequired
	}

	r.mu.RLock()
	tmpl, found := r.templates[serviceName]
	r.mu.RUnlock()

	if !found {
		return nil, fmt.Errorf("%w: %s", errTemplateNotFound, serviceName)
	}

	return tmpl, nil
}

// Has checks if a template exists for the given service (internal API).
func (r *Registry) Has(serviceName string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, found := r.templates[serviceName]
	return found
}

func (r *Registry) validate(req *proto.RegisterTemplateRequest) error {
	if req.ServiceName == "" {
		return errServiceNameRequired
	}
	if len(req.TemplateData) == 0 {
		return errTemplateDataEmpty
	}

	format := strings.ToLower(req.Format)
	if format != "json" && format != "toml" {
		return errFormatInvalid
	}

	return nil
}
