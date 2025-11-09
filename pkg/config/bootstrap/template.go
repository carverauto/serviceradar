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

package bootstrap

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errTemplateDataEmpty    = errors.New("template data is empty")
	errCoreAddressNotSet    = errors.New("CORE_ADDRESS environment variable not set")
	errTemplateRegistration = errors.New("failed to register template with core")
)

const (
	defaultTemplateRegistrationTimeout = 10 * time.Second
)

// RegisterTemplateOptions configures template registration behavior.
type RegisterTemplateOptions struct {
	// ServiceName from the descriptor (required)
	ServiceName string
	// TemplateData is the raw config bytes to register (required)
	TemplateData []byte
	// Format is the config format (json or toml)
	Format config.ConfigFormat
	// ServiceVersion is an optional semver for the template
	ServiceVersion string
	// CoreAddress overrides the CORE_ADDRESS env var
	CoreAddress string
	// Timeout for the registration RPC (default: 10s)
	Timeout time.Duration
	// Logger for diagnostic messages
	Logger logger.Logger
	// Role identifies the calling service for SPIFFE/mTLS auth
	Role models.ServiceRole
}

// RegisterTemplate registers a service's default configuration template with the core service.
// This should be called during service startup, after the service has loaded its own config
// but before it starts serving. The template will be used by the admin UI for on-demand seeding.
//
// If CORE_ADDRESS is not set or core is unreachable, this function logs a warning but does not
// return an error, allowing services to start even when core is unavailable.
func RegisterTemplate(ctx context.Context, opts RegisterTemplateOptions) error {
	if len(opts.TemplateData) == 0 {
		return errTemplateDataEmpty
	}

	if opts.Logger == nil {
		opts.Logger = logger.NewTestLogger()
	}

	// Determine core address
	coreAddr := opts.CoreAddress
	if coreAddr == "" {
		coreAddr = os.Getenv("CORE_ADDRESS")
	}
	if coreAddr == "" {
		// Core address not configured - service might be running standalone or core might not exist yet
		opts.Logger.Debug().Msg("CORE_ADDRESS not set; skipping template registration")
		return nil
	}

	// Set timeout
	timeout := opts.Timeout
	if timeout == 0 {
		timeout = defaultTemplateRegistrationTimeout
	}

	regCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Connect to core
	dialOpts, provider, err := BuildCoreDialOptionsFromEnv(regCtx, opts.Role, opts.Logger)
	if err != nil {
		if opts.Logger != nil {
			opts.Logger.Warn().Err(err).Msg("unable to build secure dial options for core; falling back to insecure transport")
		}
		dialOpts = []grpc.DialOption{
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithBlock(),
		}
	}

	conn, err := grpc.DialContext(regCtx, coreAddr, dialOpts...)
	if err != nil {
		// Core unreachable - log warning but don't fail service startup
		opts.Logger.Warn().
			Err(err).
			Str("core_address", coreAddr).
			Msg("failed to connect to core for template registration; continuing anyway")
		return nil
	}
	defer func() { _ = conn.Close() }()
	defer func() {
		if provider != nil {
			_ = provider.Close()
		}
	}()

	client := proto.NewCoreServiceClient(conn)

	// Register template
	resp, err := client.RegisterTemplate(regCtx, &proto.RegisterTemplateRequest{
		ServiceName:    opts.ServiceName,
		TemplateData:   opts.TemplateData,
		Format:         string(opts.Format),
		ServiceVersion: opts.ServiceVersion,
	})
	if err != nil {
		opts.Logger.Warn().
			Err(err).
			Str("service", opts.ServiceName).
			Msg("template registration failed; continuing anyway")
		return nil
	}

	if !resp.Success {
		opts.Logger.Warn().
			Str("service", opts.ServiceName).
			Str("message", resp.Message).
			Msg("template registration unsuccessful")
		return nil
	}

	opts.Logger.Info().
		Str("service", opts.ServiceName).
		Str("format", string(opts.Format)).
		Int("size_bytes", len(opts.TemplateData)).
		Msg("template registered with core")

	return nil
}

// RegisterTemplateFromFile reads a template file and registers it with core.
// This is a convenience wrapper around RegisterTemplate for services that embed
// their default configs as files.
func RegisterTemplateFromFile(ctx context.Context, descriptor config.ServiceDescriptor, templatePath string, logger logger.Logger) error {
	data, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Errorf("failed to read template file %s: %w", templatePath, err)
	}

	return RegisterTemplate(ctx, RegisterTemplateOptions{
		ServiceName:  descriptor.Name,
		TemplateData: data,
		Format:       descriptor.Format,
		Logger:       logger,
	})
}

// RegisterTemplateFromBytes is a convenience wrapper for registering embedded templates.
// Use this when services embed their default config via //go:embed.
func RegisterTemplateFromBytes(ctx context.Context, descriptor config.ServiceDescriptor, templateData []byte, logger logger.Logger) error {
	return RegisterTemplate(ctx, RegisterTemplateOptions{
		ServiceName:  descriptor.Name,
		TemplateData: templateData,
		Format:       descriptor.Format,
		Logger:       logger,
	})
}

// ServiceWithTemplateRegistration is a convenience function that combines Service() with template registration.
// This is the recommended way for Go services to bootstrap their configuration.
func ServiceWithTemplateRegistration(
	ctx context.Context,
	desc config.ServiceDescriptor,
	cfg interface{},
	templateData []byte,
	opts ServiceOptions,
) (*Result, error) {
	// Load config first
	result, err := Service(ctx, desc, cfg, opts)
	if err != nil {
		return nil, err
	}

	// Then register template with core (best-effort)
	if len(templateData) > 0 {
		regErr := RegisterTemplate(ctx, RegisterTemplateOptions{
			ServiceName:  desc.Name,
			TemplateData: templateData,
			Format:       desc.Format,
			Logger:       opts.Logger,
			Role:         opts.Role,
		})
		if regErr != nil {
			// Log but don't fail - template registration is optional
			if opts.Logger != nil {
				opts.Logger.Warn().
					Err(regErr).
					Str("service", desc.Name).
					Msg("failed to register template; service will continue")
			}
		}
	}

	return result, nil
}
