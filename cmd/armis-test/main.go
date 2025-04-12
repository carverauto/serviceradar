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

package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
)

type mockKVWriter struct{}

func (m *mockKVWriter) WriteSweepConfig(ctx context.Context, sweepConfig *models.SweepConfig) error {
	log.Printf("Would write to KV: Networks=%v", sweepConfig.Networks)
	return nil
}

func main() {
	// Fetch configuration from environment variables
	apiKey := os.Getenv("ARMIS_APIKEY")
	endpoint := os.Getenv("ARMIS_ENDPOINT")
	queriesEnv := os.Getenv("ARMIS_QUERIES") // Format: "label1:query1|label2:query2"

	if apiKey == "" || endpoint == "" || queriesEnv == "" {
		log.Fatal("ARMIS_APIKEY, ARMIS_ENDPOINT, and ARMIS_QUERIES must be set")
	}

	ctx := context.Background()

	// Parse queries from ARMIS_QUERIES using '|' as delimiter
	var queries []models.QueryConfig
	pairs := strings.Split(queriesEnv, "|")
	for _, pair := range pairs {
		parts := strings.SplitN(pair, ":", 2)
		if len(parts) != 2 {
			log.Fatalf("Invalid query format in ARMIS_QUERIES: %s (use 'label:query|label:query' format)", pair)
		}
		queries = append(queries, models.QueryConfig{
			Label: strings.TrimSpace(parts[0]),
			Query: strings.TrimSpace(parts[1]),
		})
	}

	// Configure Armis integration
	config := models.SourceConfig{
		Endpoint: endpoint,
		Prefix:   "armis/",
		Credentials: map[string]string{
			"secret_key": apiKey,
		},
		Queries: queries,
	}

	httpClient := &http.Client{Timeout: 30 * time.Second}
	defaultImpl := &armis.DefaultArmisIntegration{
		Config:     config,
		HTTPClient: httpClient,
	}

	integration := &armis.ArmisIntegration{
		Config:        config,
		PageSize:      100,
		TokenProvider: defaultImpl,
		DeviceFetcher: defaultImpl,
		KVWriter:      &mockKVWriter{},
	}

	// Test token fetch
	token, err := integration.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		log.Fatalf("Failed to get access token: %v", err)
	}
	log.Printf("Successfully fetched access token: %s", token)

	// Run fetch
	result, err := integration.Fetch(ctx)
	if err != nil {
		log.Fatalf("Fetch failed: %v", err)
	}

	log.Printf("Fetched %d devices:", len(result))
	for key, value := range result {
		log.Printf("Device %s: %s", key, string(value))
	}
}
