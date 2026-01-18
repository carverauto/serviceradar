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
	"strings"
	"time"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errTemplateDataEmpty    = errors.New("template data is empty")
	errCoreAddressNotSet    = errors.New("CORE_ADDRESS environment variable not set")
	errTemplateRegistration = errors.New("failed to register template with core")
)

const templatePublishTimeout = 5 * time.Second

// ServiceWithTemplateRegistration is a convenience function that combines Service() with
// template registration to core for tooling that needs default config templates.
func ServiceWithTemplateRegistration(
	ctx context.Context,
	desc config.ServiceDescriptor,
	cfg interface{},
	templateData []byte,
	opts ServiceOptions,
) (*Result, error) {
	result, err := Service(ctx, desc, cfg, opts)
	if err != nil {
		return nil, err
	}

	if len(templateData) > 0 {
		if err := registerTemplateWithCore(ctx, desc, cfg, templateData, opts); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn().
					Err(err).
					Str("service", desc.Name).
					Msg("failed to register configuration template; service will continue")
			}
		}
	}

	return result, nil
}

func registerTemplateWithCore(ctx context.Context, desc config.ServiceDescriptor, _ interface{}, templateData []byte, opts ServiceOptions) error {
	if len(templateData) == 0 {
		return errTemplateDataEmpty
	}

	log := opts.Logger
	if log == nil {
		log = logger.NewTestLogger()
	}

	coreAddr := strings.TrimSpace(os.Getenv("CORE_ADDRESS"))
	if coreAddr == "" {
		return errCoreAddressNotSet
	}

	regCtx, cancel := context.WithTimeout(ctx, templatePublishTimeout)
	defer cancel()

	dialOpts, closeProvider, err := BuildCoreDialOptionsFromEnv(regCtx, opts.Role, log)
	if err != nil {
		return fmt.Errorf("%w: %w", errTemplateRegistration, err)
	}

	conn, err := grpc.NewClient(coreAddr, dialOpts...)
	if err != nil {
		closeProvider()
		return fmt.Errorf("%w: %w", errTemplateRegistration, err)
	}
	defer func() {
		if closeErr := conn.Close(); closeErr != nil {
			log.Warn().Err(closeErr).Msg("failed to close core template connection")
		}
	}()
	defer closeProvider()

	client := proto.NewCoreServiceClient(conn)

	resp, err := client.RegisterTemplate(regCtx, &proto.RegisterTemplateRequest{
		ServiceName:  desc.Name,
		TemplateData: templateData,
		Format:       string(desc.Format),
	})
	if err != nil {
		return fmt.Errorf("%w: %w", errTemplateRegistration, err)
	}

	if !resp.GetSuccess() {
		msg := strings.TrimSpace(resp.GetMessage())
		if msg == "" {
			msg = "core rejected template"
		}
		return fmt.Errorf("%w: %s", errTemplateRegistration, msg)
	}

	log.Debug().
		Str("service", desc.Name).
		Msg("registered configuration template with core")

	return nil
}
