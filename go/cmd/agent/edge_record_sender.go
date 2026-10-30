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
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	edgesender "github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// One bounded durable-bulk delivery session is attempted per poll interval.
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
// Sweep-enabled senders persist validated terminal dispositions before advancing
// their local resolved prefix, then reclaim a fully accepted drained segment.
//
// Setup is not retried: if any setup step fails (missing gateway address or
// spool_dir, spool id, security provider before its certificate files exist,
// or client construction), the failure is logged once and the sender stays
// stopped until the agent process restarts.
func runEdgeRecordSender(ctx context.Context, cfg *agent.ServerConfig, sp *spool.Spool, log logger.Logger) {
	esCfg := cfg.EdgeRecordSender
	if esCfg == nil || !esCfg.Enabled || sp == nil {
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
		SpoolID:                 spoolID,
		RouteProfile:            edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:            edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		RequestedByteCredits:    edgeRecordSenderRequestedByteCredits,
		RequestedFrameCredits:   edgeRecordSenderRequestedFrameCreds,
		PersistAcknowledgements: esCfg.SweepEnabled,
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
	runCtx, cancel := context.WithTimeout(ctx, defaultEdgeRecordSenderPollInterval)
	defer cancel()
	result, err := s.RunOnce(runCtx)
	if err != nil {
		if errors.Is(err, edgesender.ErrNoUnresolvedRecords) {
			return
		}
		// A failed run still reports the highest sequence it sent and how far
		// the gateway acknowledged: a run that never received a durability
		// ack must show a remote prefix below the entries it attempted.
		log.Warn().Err(err).
			Int("sent", len(result.Sent)).
			Uint64("highest_sent", highestSentSequence(result)).
			Uint64("remote_resolved_through", result.RemoteResolvedThrough).
			Msg("Edge record sender run failed")
		return
	}

	log.Info().
		Int("sent", len(result.Sent)).
		Uint64("highest_sent", highestSentSequence(result)).
		Int("dispositions", len(result.Dispositions)).
		Uint64("remote_resolved_through", result.RemoteResolvedThrough).
		Msg("Edge record sender drained spool lane")
}

// highestSentSequence is the last sequence a run sent, or 0 when it sent
// none. The sender appends sequences in spool order.
func highestSentSequence(result edgesender.Result) uint64 {
	if n := len(result.Sent); n > 0 {
		return result.Sent[n-1]
	}
	return 0
}

// openEdgeRecordSpool is called once for the process; producer and sender share
// its mutex, sequence allocation, recovery state and byte allocator.
func openEdgeRecordSpool(cfg *agent.ServerConfig) (*spool.Spool, error) {
	c := cfg.EdgeRecordSender
	if c == nil {
		return nil, nil
	}
	if !c.Enabled {
		if c.SweepEnabled {
			return nil, errors.New("edge sweep requires enabled edge record sender")
		}
		return nil, nil
	}
	if c.SpoolDir == "" {
		return nil, errors.New("edge record sender requires spool_dir")
	}
	capacity := c.MaxBytes
	if capacity == 0 {
		capacity = 256 << 20
	}
	allocator, err := spool.NewAllocator(spool.AllocatorConfig{
		Capacity: capacity, MinFree: 1 << 20, MaxConcurrentRecoveries: 1,
		Recovery: spool.Footprint{DestinationSegment: 1 << 20, AttributionSidecar: 64 << 10, JournalCopy: 64 << 10, ManifestPages: 256 << 10, Mapping: 64 << 10, FilesystemMetadata: 64 << 10},
	})
	if err != nil {
		return nil, fmt.Errorf("edge spool capacity: %w", err)
	}
	return spool.Open(c.SpoolDir, spool.WithAllocator(allocator))
}
