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
	errTemplateDataEmpty          = errors.New("template data is empty")
	errTemplateStorageUnavailable = errors.New("template storage unavailable")
	errCoreAddressNotSet          = errors.New("CORE_ADDRESS environment variable not set")
	errTemplateRegistration       = errors.New("failed to register template with core")
)

const (
	templatePublishTimeout      = 5 * time.Second
	templatePublishRetryBackoff = 30 * time.Second
)

// ServiceWithTemplateRegistration is a convenience function that combines Service() with template publishing.
// Each service loads its configuration, then writes its embedded default template to the KV-backed template store
// so that the Admin API (and other tooling) can seed missing configs without requiring the workload to contact
// the core service directly.
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
		if err := publishTemplateWithFallback(ctx, result.Manager(), desc, cfg, templateData, opts); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn().
					Err(err).
					Str("service", desc.Name).
					Msg("failed to publish configuration template; service will continue")
			}
		}
	}

	return result, nil
}

func publishTemplateWithFallback(ctx context.Context, manager *config.KVManager, desc config.ServiceDescriptor, cfg interface{}, templateData []byte, opts ServiceOptions) error {
	if len(templateData) == 0 {
		return errTemplateDataEmpty
	}

	var kvErr error
	hasManager := manager != nil
	if hasManager {
		kvErr = persistTemplateToKV(ctx, manager, desc, templateData, opts.Logger)
		if kvErr == nil {
			return nil
		}
	} else {
		kvErr = errTemplateStorageUnavailable
	}

	regErr := registerTemplateWithCore(ctx, desc, cfg, templateData, opts)
	if regErr == nil {
		return nil
	}

	if kvErr == nil || errors.Is(kvErr, errTemplateStorageUnavailable) {
		return regErr
	}

	return fmt.Errorf("kv template publish failed: %w; core registration failed: %w", kvErr, regErr)
}

func persistTemplateToKV(ctx context.Context, manager *config.KVManager, desc config.ServiceDescriptor, templateData []byte, log logger.Logger) error {
	if len(templateData) == 0 {
		return errTemplateDataEmpty
	}
	if manager == nil {
		return errTemplateStorageUnavailable
	}

	templateKey := config.TemplateStorageKey(desc)
	if templateKey == "" {
		return errTemplateStorageUnavailable
	}

	if log == nil {
		log = logger.NewTestLogger()
	}

	publishOnce := func(ctx context.Context) error {
		writeCtx, cancel := context.WithTimeout(ctx, templatePublishTimeout)
		defer cancel()
		return manager.Put(writeCtx, templateKey, templateData, 0)
	}

	if err := publishOnce(ctx); err != nil {
		log.Warn().
			Err(err).
			Str("service", desc.Name).
			Str("template_key", templateKey).
			Msg("failed to publish configuration template; will retry in background")

		go retryTemplatePublish(ctx, manager, templateKey, desc.Name, templateData, log)
		return err
	}

	log.Debug().
		Str("service", desc.Name).
		Str("template_key", templateKey).
		Msg("published configuration template to KV")
	return nil
}

func retryTemplatePublish(
	ctx context.Context,
	manager *config.KVManager,
	templateKey string,
	serviceName string,
	templateData []byte,
	log logger.Logger,
) {
	ticker := time.NewTicker(templatePublishRetryBackoff)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := manager.Put(context.Background(), templateKey, templateData, 0); err != nil {
				log.Warn().
					Err(err).
					Str("service", serviceName).
					Str("template_key", templateKey).
					Msg("retrying template publish failed")
				continue
			}

			log.Info().
				Str("service", serviceName).
				Str("template_key", templateKey).
				Msg("published configuration template to KV after retry")
			return
		}
	}
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
		return fmt.Errorf("%w: %s", errTemplateRegistration, resp.GetMessage())
	}

	log.Debug().
		Str("service", desc.Name).
		Str("core_address", coreAddr).
		Msg("published configuration template to core registry")

	return nil
}
