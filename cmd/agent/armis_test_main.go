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
	ctx := context.Background()

	config := models.SourceConfig{
		Endpoint: os.Getenv("ARMIS_ENDPOINT"),
		Prefix:   "armis/",
		Credentials: map[string]string{
			"secret_key": os.Getenv("ARMIS_SECRET_KEY"),
			"boundary":   os.Getenv("ARMIS_BOUNDARY"),
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
		BoundaryName:  os.Getenv("ARMIS_BOUNDARY"),
		TokenProvider: defaultImpl,
		DeviceFetcher: defaultImpl,
		KVWriter:      &mockKVWriter{},
	}

	result, err := integration.Fetch(ctx)
	if err != nil {
		log.Fatalf("Fetch failed: %v", err)
	}

	log.Printf("Fetched %d devices:", len(result))
	for key, value := range result {
		log.Printf("Device %s: %s", key, string(value))
	}
}
