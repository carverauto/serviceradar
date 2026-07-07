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

// Package armis implements the Armis sync-source driver for the agent sync
// runtime. It owns the Armis API client (token handling, AQL search,
// pagination) and the mapping from Armis device records to ServiceRadar
// device updates.
package armis

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// SourceType identifies the Armis integration in the sync-source registry.
const SourceType = "armis"

const defaultPageSize = 100

var errNoQueriesConfigured = errors.New("armis source has no queries configured")

// Driver syncs device inventory from the Armis cloud API.
type Driver struct{}

// NewDriver constructs the Armis sync-source driver.
func NewDriver() syncsources.SourceDriver {
	return &Driver{}
}

// Sync runs every configured AQL query, paginating through results and
// emitting one batch of device updates per fetched page.
func (d *Driver) Sync(ctx context.Context, run syncsources.RunContext) (int, error) {
	apiClient := newClient(run.Source)
	queries := configuredQueries(run.Source.Queries)
	if len(queries) == 0 {
		return 0, errNoQueriesConfigured
	}

	token, err := apiClient.accessToken(ctx, run.Source.Credentials)
	if err != nil {
		return 0, err
	}

	size := pageSize(run.Source)
	assetConfig := newAssetEnrichmentConfig(run.Source)
	totalUpdates := 0
	tokenRefreshes := 0

	var assetToken string
	if len(assetConfig.fields) > 0 {
		assetToken, err = apiClient.v3AccessToken(ctx, run.Source, assetConfig)
		if err != nil {
			return 0, err
		}
	}

	run.Logger.Info().
		Str("source", run.SourceKey).
		Str("run_id", run.RunID).
		Str("sync_service_id", run.Source.SyncServiceID).
		Int("query_count", len(queries)).
		Int("page_size", size).
		Int("armis_asset_field_count", len(assetConfig.fields)).
		Msg("Starting Armis sync")

	for queryIndex, query := range queries {
		queryString := query.Query
		queryLabel := query.Label

		from := 0
		pageIndex := 0
		for {
			resp, err := apiClient.search(ctx, token, queryString, from, size)
			if err != nil && isUnauthorized(err) {
				tokenRefreshes++
				run.Logger.Warn().
					Err(err).
					Str("source", run.SourceKey).
					Str("run_id", run.RunID).
					Str("query_label", queryLabel).
					Int("query_index", queryIndex).
					Int("page_index", pageIndex).
					Int("from", from).
					Int("token_refresh_count", tokenRefreshes).
					Msg("Armis search unauthorized; refreshing access token")

				refreshedToken, tokenErr := apiClient.accessToken(ctx, run.Source.Credentials)
				if tokenErr == nil {
					token = refreshedToken
					resp, err = apiClient.search(ctx, token, queryString, from, size)
				} else {
					err = fmt.Errorf("%w; token refresh failed: %w", err, tokenErr)
				}
			}
			if err != nil {
				if totalUpdates > 0 {
					return totalUpdates, fmt.Errorf("partial armis sync after streaming %d devices: %w", totalUpdates, err)
				}

				return totalUpdates, err
			}

			filtered := filterDevices(resp.Data.Results, run.Source.NetworkBlacklist)
			if len(assetConfig.fields) > 0 {
				filtered, err = apiClient.enrichAssetFields(ctx, assetToken, assetConfig, filtered)
				if err != nil {
					if totalUpdates > 0 {
						return totalUpdates, fmt.Errorf("partial armis sync after streaming %d devices: %w", totalUpdates, err)
					}

					return totalUpdates, err
				}
			}
			logDeviceShape(run, queryLabel, from, filtered)

			updates := make([]map[string]interface{}, 0, len(filtered))
			for _, item := range filtered {
				update := buildUpdate(run, item, queryLabel)
				if update == nil {
					continue
				}
				updates = append(updates, update)
			}

			if len(updates) > 0 {
				if err := run.Emit(updates); err != nil {
					return totalUpdates, err
				}
				totalUpdates += len(updates)
			}

			run.Logger.Info().
				Str("source", run.SourceKey).
				Str("run_id", run.RunID).
				Str("query_label", queryLabel).
				Int("query_index", queryIndex).
				Int("page_index", pageIndex).
				Int("from", from).
				Int("length", size).
				Int("armis_result_count", len(resp.Data.Results)).
				Int("filtered_count", len(filtered)).
				Int("streamed_count", len(updates)).
				Int("run_streamed_total", totalUpdates).
				Int("armis_total", resp.Data.Total).
				Int("next", resp.Data.Next).
				Int("token_refresh_count", tokenRefreshes).
				Msg("Armis page streamed")

			if resp.Data.Next <= 0 || resp.Data.Next <= from {
				break
			}

			from = resp.Data.Next
			pageIndex++
		}
	}

	return totalUpdates, nil
}

func logDeviceShape(run syncsources.RunContext, queryLabel string, from int, devices []device) {
	interfaceDeviceCount := 0
	var sampleInterfaceKeys []string

	for _, item := range devices {
		if len(item.NetworkInterfaces) == 0 {
			continue
		}

		interfaceDeviceCount++
		if len(sampleInterfaceKeys) == 0 {
			sampleInterfaceKeys = sortedMapKeys(item.NetworkInterfaces[0])
		}
	}

	boundaryDeviceCount := 0
	var sampleBoundaryNames []string
	for _, item := range devices {
		names := boundaryNames(item.Boundaries)
		if len(names) == 0 {
			continue
		}

		boundaryDeviceCount++
		if len(sampleBoundaryNames) == 0 {
			sampleBoundaryNames = names
		}
	}

	if interfaceDeviceCount == 0 && boundaryDeviceCount == 0 {
		return
	}

	run.Logger.Info().
		Str("source", SourceType).
		Str("run_id", run.RunID).
		Str("query_label", queryLabel).
		Int("from", from).
		Int("device_count", len(devices)).
		Int("devices_with_network_interfaces", interfaceDeviceCount).
		Strs("network_interface_sample_keys", sampleInterfaceKeys).
		Int("devices_with_boundaries", boundaryDeviceCount).
		Strs("boundary_sample_names", sampleBoundaryNames).
		Msg("Armis device shape sample")
}

func pageSize(source models.SourceConfig) int {
	value := source.Credentials["page_size"]
	if value == "" {
		return defaultPageSize
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return defaultPageSize
	}
	return parsed
}

func configuredQueries(queries []models.QueryConfig) []models.QueryConfig {
	configured := make([]models.QueryConfig, 0, len(queries))
	for _, query := range queries {
		query.Query = normalizeQuery(query.Query)
		if query.Query == "" {
			continue
		}

		configured = append(configured, query)
	}

	return configured
}

func normalizeQuery(query string) string {
	query = strings.TrimSpace(query)
	return strings.ReplaceAll(query, `\"`, `"`)
}
