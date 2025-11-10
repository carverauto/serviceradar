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
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
)

var (
	errTemplateDataEmpty          = errors.New("template data is empty")
	errTemplateStorageUnavailable = errors.New("template storage unavailable")
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
		if err := persistTemplateToKV(ctx, result.Manager(), desc, templateData, opts.Logger); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn().
					Err(err).
					Str("service", desc.Name).
					Msg("failed to publish template to KV; service will continue")
			}
		}
	}

	return result, nil
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
