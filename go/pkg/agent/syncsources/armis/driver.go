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
	"sort"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// SourceType identifies the Armis integration in the sync-source registry.
const SourceType = "armis"

const (
	defaultPageSize            = 100
	populationExampleLimit     = 100
	duplicateConflictFlagValue = "true"
)

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
	population := syncsources.PopulationStats{}
	seen := make(map[string]duplicateIdentity)
	conflictUpdates := make(map[string]map[string]interface{})
	conflictingDuplicateIDs := make(map[string]struct{})
	conflictSignalsEmitted := make(map[string]struct{})
	duplicateExamples := make([]string, 0, populationExampleLimit)
	invalidExamples := make([]string, 0, populationExampleLimit)

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

			population.RawRows += len(resp.Data.Results)
			filtered := filterDevices(resp.Data.Results, run.Source.NetworkBlacklist)
			population.ExcludedRows += len(resp.Data.Results) - len(filtered)
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
			pendingUpdates := make(map[string]map[string]interface{}, len(filtered))
			for itemIndex, item := range filtered {
				update := buildUpdate(run, item, queryLabel)
				if update == nil {
					population.InvalidRows++
					invalidExamples = appendBoundedExample(
						invalidExamples,
						fmt.Sprintf("query=%s page=%d row=%d", queryLabel, pageIndex, itemIndex),
					)
					continue
				}

				armisID := armisIDFromUpdate(update)
				if armisID == "" {
					population.InvalidRows++
					invalidExamples = appendBoundedExample(
						invalidExamples,
						fmt.Sprintf("query=%s page=%d row=%d", queryLabel, pageIndex, itemIndex),
					)
					continue
				}

				population.ValidOccurrences++
				signature := duplicateIdentitySignature(update)
				if existingSignature, duplicate := seen[armisID]; duplicate {
					population.DuplicateOccurrences++
					duplicateExamples = appendBoundedExample(duplicateExamples, armisID)
					if conflictingDuplicateSignature(existingSignature, signature) {
						conflictingDuplicateIDs[armisID] = struct{}{}
						if _, emitted := conflictSignalsEmitted[armisID]; !emitted {
							if firstUpdate, pending := pendingUpdates[armisID]; pending {
								markDuplicateConflict(firstUpdate)
							} else {
								updates = append(updates, conflictUpdates[armisID])
							}
							conflictSignalsEmitted[armisID] = struct{}{}
						}
					}
					seen[armisID] = mergeDuplicateIdentity(existingSignature, signature)
					continue
				}

				seen[armisID] = signature
				conflictUpdates[armisID] = duplicateConflictUpdate(update)
				pendingUpdates[armisID] = update
				updates = append(updates, update)
			}

			population.DistinctSourceIDs = len(seen)
			population.DuplicateSourceIDExamples = duplicateExamples
			population.InvalidRowExamples = invalidExamples
			population.ConflictingDuplicateIDs = sortedKeys(conflictingDuplicateIDs)
			if run.ReportPopulation != nil {
				run.ReportPopulation(population)
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

	population.DistinctSourceIDs = len(seen)
	population.DuplicateSourceIDExamples = duplicateExamples
	population.InvalidRowExamples = invalidExamples
	population.ConflictingDuplicateIDs = sortedKeys(conflictingDuplicateIDs)
	if run.ReportPopulation != nil {
		run.ReportPopulation(population)
	}

	return totalUpdates, nil
}

// duplicateConflictUpdate retains only the identity fields needed to re-emit
// a monotonic conflict marker after the first observation has been streamed.
// Large descriptive fields such as network_interfaces must not be retained
// for every distinct source ID for the lifetime of a collection.
func duplicateConflictUpdate(update map[string]interface{}) map[string]interface{} {
	result := make(map[string]interface{}, 10)
	for _, key := range []string{
		"agent_id", "gateway_id", "partition", "device_id", "ip", "source", "timestamp", "mac", "hostname",
	} {
		if value, ok := update[key]; ok {
			result[key] = value
		}
	}

	metadata, _ := update["metadata"].(map[string]string)
	result["metadata"] = duplicateConflictMetadata(metadata)

	return result
}

func duplicateConflictMetadata(metadata map[string]string) map[string]string {
	result := make(map[string]string, 7)
	for _, key := range []string{
		"integration_type", "armis_device_id", "integration_id", "source_device_id", "serial_number",
		"serial_numbers", "mac_addresses",
	} {
		if value := metadata[key]; value != "" {
			result[key] = value
		}
	}
	result["source_duplicate_conflict"] = duplicateConflictFlagValue

	return result
}

func markDuplicateConflict(update map[string]interface{}) {
	metadata, _ := update["metadata"].(map[string]string)
	metadataCopy := make(map[string]string, len(metadata)+1)
	for key, value := range metadata {
		metadataCopy[key] = value
	}
	metadataCopy["source_duplicate_conflict"] = duplicateConflictFlagValue
	update["metadata"] = metadataCopy
}

func armisIDFromUpdate(update map[string]interface{}) string {
	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		return ""
	}

	return strings.TrimSpace(metadata["armis_device_id"])
}

type duplicateIdentity struct {
	serials []string
	macs    []string
}

// duplicateIdentitySignature intentionally excludes IP, hostname, and other
// descriptive fields. IPs churn and query projections can differ. A repeated
// source ID conflicts only when both observations carry disjoint, non-empty
// values for the same hardware-anchor field.
func duplicateIdentitySignature(update map[string]interface{}) duplicateIdentity {
	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		return duplicateIdentity{}
	}

	return duplicateIdentity{
		serials: normalizedValues(metadata["serial_numbers"]),
		macs:    normalizedValues(metadata["mac_addresses"]),
	}
}

func conflictingDuplicateSignature(existing, incoming duplicateIdentity) bool {
	return disjointNonEmpty(existing.serials, incoming.serials) ||
		disjointNonEmpty(existing.macs, incoming.macs)
}

func mergeDuplicateIdentity(existing, incoming duplicateIdentity) duplicateIdentity {
	return duplicateIdentity{
		serials: mergeNormalizedValues(existing.serials, incoming.serials),
		macs:    mergeNormalizedValues(existing.macs, incoming.macs),
	}
}

func normalizedValues(value string) []string {
	parts := strings.Split(value, ",")
	normalized := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		part = strings.ToUpper(strings.TrimSpace(part))
		if part == "" {
			continue
		}
		if _, duplicate := seen[part]; duplicate {
			continue
		}
		seen[part] = struct{}{}
		normalized = append(normalized, part)
	}
	sort.Strings(normalized)
	return normalized
}

func disjointNonEmpty(left, right []string) bool {
	if len(left) == 0 || len(right) == 0 {
		return false
	}

	leftSet := make(map[string]struct{}, len(left))
	for _, value := range left {
		leftSet[value] = struct{}{}
	}
	for _, value := range right {
		if _, overlaps := leftSet[value]; overlaps {
			return false
		}
	}
	return true
}

func mergeNormalizedValues(left, right []string) []string {
	merged := append(append([]string(nil), left...), right...)
	return normalizedValues(strings.Join(merged, ","))
}

func sortedKeys(values map[string]struct{}) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func appendBoundedExample(examples []string, value string) []string {
	if len(examples) >= 100 {
		return examples
	}
	for _, existing := range examples {
		if existing == value {
			return examples
		}
	}
	return append(examples, value)
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
