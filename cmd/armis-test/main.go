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
	boundary := os.Getenv("ARMIS_BOUNDARY")

	if apiKey == "" || endpoint == "" {
		log.Fatal("ARMIS_APIKEY and ARMIS_ENDPOINT must be set")
	}

	// Allow boundary to be optional
	if boundary == "" {
		log.Println("ARMIS_BOUNDARY not set, proceeding without boundary filter")
	}

	ctx := context.Background()

	// Configure Armis integration
	config := models.SourceConfig{
		Endpoint: endpoint,
		Prefix:   "armis/",
		Credentials: map[string]string{
			"secret_key": apiKey,
		},
	}

	httpClient := &http.Client{Timeout: 30 * time.Second}
	defaultImpl := &armis.DefaultArmisIntegration{
		Config:     config,
		HTTPClient: httpClient,
	}

	integration := &armis.ArmisIntegration{
		Config:        config,
		PageSize:      100,
		BoundaryName:  boundary, // Use empty string if not set
		TokenProvider: defaultImpl,
		DeviceFetcher: defaultImpl,
		KVWriter:      &mockKVWriter{},
	}

	// Run the fetch against real Armis
	result, err := integration.Fetch(ctx)
	if err != nil {
		log.Fatalf("Fetch failed: %v", err)
	}

	log.Printf("Fetched %d devices:", len(result))

	for key, value := range result {
		log.Printf("Device %s: %s", key, string(value))
	}
}
