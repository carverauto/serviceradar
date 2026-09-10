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

package main

import (
	"context"
	"errors"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	edgesender "github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Defaults for the minimum edge-record sender (task 0.12 of
// openspec/changes/unify-sweep-results-proto). These are deliberately fixed,
// not configurable: task 0.12 scopes this to one durable-bulk lane driving
// one synthetic fixture through the composed path, not a general-purpose,
// tunable producer.
const (
	defaultEdgeRecordSenderPollInterval  = 30 * time.Second
	edgeRecordSenderRequestedByteCredits = 8 << 20 // 8 MiB
	edgeRecordSenderRequestedFrameCreds  = 256
)

// runEdgeRecordSender drains cfg.EdgeRecordSender's agent spool over a
// dedicated EdgeRecordIngestService.Stream mTLS connection: one bounded lane
// session per poll tick, for as long as ctx stays alive. It is a no-op unless
// explicitly enabled in config, since the gateway-side RPC server this
// depends on (a separate, parallel task) may not exist in every deployment.
//
// This is intentionally the minimum sender: no reconnect/replay, no recovery/
// rollover, and it never calls (*spool.Spool).Resolve -- see the sender
// package doc for why a gateway ack alone must not reclaim the spool.
func runEdgeRecordSender(ctx context.Context, cfg *agent.ServerConfig, log logger.Logger) {
	esCfg := cfg.EdgeRecordSender
	if esCfg == nil || !esCfg.Enabled {
		return
	}

	addr := esCfg.GatewayAddr
	if addr == "" {
		addr = cfg.GatewayAddr
	}
	security := esCfg.Security
	if security == nil {
		security = cfg.GatewaySecurity
	}
	if addr == "" {
		log.Error().Msg("Edge record sender enabled without a gateway address")
		return
	}
	if esCfg.SpoolDir == "" {
		log.Error().Msg("Edge record sender enabled without a spool_dir")
		return
	}

	interval := time.Duration(esCfg.PollInterval)
	if interval <= 0 {
		interval = defaultEdgeRecordSenderPollInterval
	}

	sp, err := spool.Open(esCfg.SpoolDir)
	if err != nil {
		log.Error().Err(err).Str("spool_dir", esCfg.SpoolDir).Msg("Failed to open edge record spool")
		return
	}
	defer func() { _ = sp.Close() }()

	spoolID, err := edgesender.PersistentSpoolID(esCfg.SpoolDir)
	if err != nil {
		log.Error().Err(err).Msg("Failed to load edge record spool id")
		return
	}

	securityProvider, err := srgrpc.NewSecurityProvider(ctx, security, log)
	if err != nil {
		log.Error().Err(err).Msg("Failed to build edge record sender security provider")
		return
	}
	defer func() { _ = securityProvider.Close() }()

	client, err := srgrpc.NewClient(ctx, srgrpc.ClientConfig{
		Address:          addr,
		SecurityProvider: securityProvider,
		Logger:           log,
	})
	if err != nil {
		log.Error().Err(err).Str("addr", addr).Msg("Failed to dial edge record gateway")
		return
	}
	defer func() { _ = client.Close() }()

	ingestClient := edgev1.NewEdgeRecordIngestServiceClient(client.GetConnection())

	s, err := edgesender.New(sp, ingestClient, edgesender.Config{
		SpoolID:               spoolID,
		RouteProfile:          edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:          edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		RequestedByteCredits:  edgeRecordSenderRequestedByteCredits,
		RequestedFrameCredits: edgeRecordSenderRequestedFrameCreds,
	})
	if err != nil {
		log.Error().Err(err).Msg("Failed to construct edge record sender")
		return
	}

	log.Info().Str("addr", addr).Str("spool_dir", esCfg.SpoolDir).Dur("interval", interval).
		Msg("Edge record sender starting")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runEdgeRecordSenderOnce(ctx, s, log)
		}
	}
}

func runEdgeRecordSenderOnce(ctx context.Context, s *edgesender.Sender, log logger.Logger) {
	result, err := s.RunOnce(ctx)
	if err != nil {
		if errors.Is(err, edgesender.ErrNoUnresolvedRecords) {
			return
		}
		log.Warn().Err(err).Msg("Edge record sender run failed")
		return
	}

	log.Info().
		Int("sent", len(result.Sent)).
		Int("dispositions", len(result.Dispositions)).
		Uint64("remote_resolved_through", result.RemoteResolvedThrough).
		Msg("Edge record sender drained spool lane")
}
