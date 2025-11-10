package bootstrap

import (
	"context"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/spireadmin"
)

// InitSpireAdminClient creates a SPIRE administrative client from the supplied
// core configuration. If the SPIRE admin block is disabled or incomplete the
// function returns nil without error so callers can safely proceed without the
// client.
func InitSpireAdminClient(ctx context.Context, cfg *models.CoreServiceConfig, log logger.Logger) (spireadmin.Client, error) {
	if cfg.SpireAdmin == nil || !cfg.SpireAdmin.Enabled {
		return nil, nil
	}

	spireCfg := spireadmin.Config{
		WorkloadSocket: cfg.SpireAdmin.WorkloadSocket,
		ServerAddress:  cfg.SpireAdmin.ServerAddress,
		ServerSPIFFEID: cfg.SpireAdmin.ServerSPIFFEID,
	}

	if spireCfg.ServerAddress == "" || spireCfg.ServerSPIFFEID == "" {
		log.Warn().Msg("SPIRE admin config enabled but server address or SPIFFE ID missing; disabling admin client")
		return nil, nil
	}

	client, err := spireadmin.New(ctx, spireCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize SPIRE admin client: %w", err)
	}

	return client, nil
}

// BuildAPIServerOptions produces the optional configuration hooks used when
// constructing the HTTP API server. The options returned are derived from the
// supplied configuration and environment variables.
func BuildAPIServerOptions(cfg *models.CoreServiceConfig, log logger.Logger, spireAdminClient spireadmin.Client) []func(*api.APIServer) {
	var apiOptions []func(*api.APIServer)

	if kvAddr := os.Getenv("KV_ADDRESS"); kvAddr != "" {
		apiOptions = append(apiOptions, api.WithKVAddress(kvAddr))
	}

	kvSecurity := cfg.KVSecurity
	if kvSecurity == nil {
		kvSecurity = cfg.Security
	}

	if kvSecurity != nil {
		apiOptions = append(apiOptions, api.WithKVSecurity(kvSecurity))
	}

	if len(cfg.KVEndpoints) > 0 {
		endpoints := make(map[string]*api.KVEndpoint, len(cfg.KVEndpoints))
		for _, endpoint := range cfg.KVEndpoints {
			endpoints[endpoint.ID] = &api.KVEndpoint{
				ID:       endpoint.ID,
				Name:     endpoint.Name,
				Address:  endpoint.Address,
				Domain:   endpoint.Domain,
				Type:     endpoint.Type,
				Security: kvSecurity,
			}
		}
		apiOptions = append(apiOptions, api.WithKVEndpoints(endpoints))
	}

	if cfg.SpireAdmin != nil && cfg.SpireAdmin.Enabled {
		if spireAdminClient == nil {
			log.Warn().Msg("SPIRE admin config enabled but admin client unavailable; admin APIs disabled")
		} else {
			apiOptions = append(apiOptions, api.WithSpireAdmin(spireAdminClient, cfg.SpireAdmin))
		}
	}

	return apiOptions
}
