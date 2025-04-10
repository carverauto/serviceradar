package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// WriteSweepConfig generates and writes the sweep config to KV.
func (kw *DefaultKVWriter) WriteSweepConfig(ctx context.Context, ips []string) error {
	sweepConfig := models.SweepConfig{
		Networks:      ips,
		Ports:         []int{22, 80, 443, 3306, 5432, 6379, 8080, 8443},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "5m",
		Concurrency:   100,
		Timeout:       "10s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		log.Printf("Marshaling failed: %v", err)

		return fmt.Errorf("failed to marshal sweep config: %w", err)
	}

	configKey := fmt.Sprintf("config/%s/network-sweep", kw.ServerName)
	_, err = kw.KVClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		return fmt.Errorf("failed to write sweep config to %s: %w", configKey, err)
	}

	log.Printf("Wrote sweep config to %s", configKey)

	return nil
}
