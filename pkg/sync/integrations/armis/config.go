package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// writeSweepConfig generates and writes the sweep Config to KV.
func (a *ArmisIntegration) writeSweepConfig(ctx context.Context, ips []string) {
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
		log.Printf("Failed to marshal sweep config: %v", err)

		return
	}

	configKey := fmt.Sprintf("config/%s/network-sweep", a.ServerName)
	_, err = a.KvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		log.Printf("Failed to write sweep config to %s: %v", configKey, err)

		return
	}

	log.Printf("Wrote sweep config to %s", configKey)
}
