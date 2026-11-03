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

package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

const (
	netprobeResultsPayloadMaxBytes       = 8 * 1024 * 1024
	netprobeResultsStreamPayloadMaxBytes = 48 * 1024 * 1024
)

func (p *PushLoop) pushMapperResults(ctx context.Context) bool {
	return p.pushMapperFamily(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainResults(1000)
		},
		buildMapperResultsPayload,
		discoveryMapperDevices,
		mapperServiceType,
		"update_count",
	)
}

// streamDiscoveryPayload carries one built discovery payload on the legacy
// status path as a single-chunk results stream.
func (p *PushLoop) streamDiscoveryPayload(
	ctx context.Context,
	payload []byte,
	serviceName string,
	serviceType string,
) bool {
	seq := fmt.Sprintf("%d", time.Now().UnixNano())
	response := mapperResultsResponse(payload, seq, serviceName, serviceType)
	chunks := []*proto.ResultsChunk{{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	}}

	statusChunks := p.buildResultsStatusChunks(chunks, response.ServiceName, response.ServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if _, err := p.gateway.StreamStatus(pushCtx, statusChunks); err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream discovery results to gateway")
		return false
	}
	return true
}

// pushDiscovery moves one discovery family down exactly one path. While
// the family's standing grant is current its drain goes only to the spool;
// a drain the spool will not yet admit stays the family's one pending item,
// and the family's source is not drained again until that item is admitted
// (backpressure, so nothing queues behind it). Without a grant the drain
// rides the legacy status path once; a failed send drops it and counts it.
func (p *PushLoop) pushDiscovery(
	kind discoveryKind,
	agentID string,
	partition string,
	drain func() [][]byte,
	legacySend func([]byte) bool,
) bool {
	spec := kind.spec()
	q := p.discoveryQueue(kind)
	sent := false
	if q.built != nil {
		if !p.appendDiscoveryBuilt(q.built) {
			return false
		}
		q.built = nil
		sent = true
	}

	payloads := drain()
	if len(payloads) == 0 {
		return sent
	}

	if capability := p.discoveryCapability(kind, time.Now()); capability != nil {
		built, dropped, err := buildDiscoveryItem(spec, payloads, capability, agentID, partition)
		p.dropEdgeTelemetry(spec.producer, edgeDropInvalidRecord, dropped)
		if err != nil {
			p.logger.Warn().Err(err).Str("contract", spec.contractID).
				Msg("Dropping discovery drain that cannot form an edge record")
			return sent
		}
		if !p.appendDiscoveryBuilt(built) {
			q.built = built
			return sent
		}
		return true
	}

	for i, payload := range payloads {
		if !legacySend(payload) {
			p.dropEdgeTelemetry(spec.producer, edgeDropRetryBufferFull, discoveryUpdateCount(payloads[i:]))
			return sent
		}
		sent = true
	}
	return sent
}

func (p *PushLoop) pushNetprobeResults(ctx context.Context) bool {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	var logEvent func()
	sent := p.pushDiscovery(discoveryNetprobe, agentID, partition,
		func() [][]byte {
			var payloads [][]byte
			payloads, logEvent = p.drainNetprobePayloads(agentID, partition)
			return payloads
		},
		func(data []byte) bool {
			return p.streamDiscoveryPayload(ctx, data,
				string(models.DiscoverySourcePassiveNetprobe),
				string(models.DiscoverySourcePassiveNetprobe))
		})
	if sent && logEvent != nil {
		logEvent()
	}
	return sent
}

// drainNetprobePayloads drains the netprobe sidecar and builds its
// size-bounded update payloads, with a logger for a delivered drain.
func (p *PushLoop) drainNetprobePayloads(agentID, partition string) ([][]byte, func()) {
	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	p.server.mu.RUnlock()

	// Outside the RLock on purpose: getSourceIP() takes p.server.mu.RLock
	// itself, and sync.RWMutex is not reentrant -- a writer arriving between the
	// two acquisitions deadlocks the push loop. Same reason it is getSourceIP()
	// rather than config.HostIP: the configured value is an onboard-time pin
	// that a re-IP'd host leaves stale.
	collectorIP := p.getSourceIP()

	if netprobeSidecar == nil {
		return nil, nil
	}

	fingerprintEvents := netprobeSidecar.DrainEvents(1000)
	dpiEvents := netprobeSidecar.DrainDPIEvents(1000)
	processSnapshots := netprobeSidecar.DrainProcessSnapshots(1000)
	if len(fingerprintEvents) == 0 && len(dpiEvents) == 0 && len(processSnapshots) == 0 {
		return nil, nil
	}

	opts := agentnetprobe.TranslationOptions{
		AgentID:     agentID,
		GatewayID:   p.gateway.GetGatewayID(),
		CollectorIP: collectorIP,
	}
	updates := p.netprobeUpdates(fingerprintEvents, dpiEvents, processSnapshots, opts, partition)
	if len(updates) == 0 {
		return nil, nil
	}

	payloads, skippedUpdates, err := buildNetprobeResultsPayloads(
		updates,
		netprobeResultsPayloadMaxBytes,
		netprobeResultsStreamPayloadMaxBytes,
	)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal netprobe results")
		return nil, nil
	}
	if len(payloads) == 0 {
		if skippedUpdates > 0 {
			p.logger.Warn().
				Int("skipped_update_count", skippedUpdates).
				Msg("Skipped oversized netprobe result updates")
		}
		return nil, nil
	}

	return payloads, func() {
		event := p.logger.Info()
		if skippedUpdates > 0 {
			event = p.logger.Warn().Int("skipped_update_count", skippedUpdates)
		}
		event.
			Int("fingerprint_event_count", len(fingerprintEvents)).
			Int("dpi_event_count", len(dpiEvents)).
			Int("process_snapshot_count", len(processSnapshots)).
			Int("update_count", len(updates)).
			Int("payload_count", len(payloads)).
			Msg("Streamed netprobe results to gateway")
	}
}

// netprobeUpdates translates one netprobe drain into discovery updates,
// skipping (and logging) anything the translator rejects.
func (p *PushLoop) netprobeUpdates(
	fingerprintEvents []*netprobepb.FingerprintEvent,
	dpiEvents []*netprobepb.DpiEvent,
	processSnapshots []*netprobepb.ProcessSnapshot,
	opts agentnetprobe.TranslationOptions,
	partition string,
) []map[string]any {
	updates := make([]map[string]any, 0, len(fingerprintEvents)+len(dpiEvents)+len(processSnapshots))
	add := func(device *discoverypb.DiscoveredDevice, err error, invalidMsg string, source string) {
		if err != nil {
			p.logger.Warn().Err(err).Msg(invalidMsg)
			return
		}
		if source == "" {
			source = netprobeDiscoverySource(device.GetMetadata())
		}
		updates = append(updates, map[string]any{
			"ip":         device.GetIp(),
			"agent_id":   opts.AgentID,
			"gateway_id": opts.GatewayID,
			"partition":  partition,
			"source":     source,
			"metadata":   device.GetMetadata(),
			"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
		})
	}

	passive := string(models.DiscoverySourcePassiveNetprobe)
	for _, event := range fingerprintEvents {
		device, err := agentnetprobe.FingerprintEventToDiscoveredDevice(event, opts)
		add(device, err, "Skipping invalid netprobe fingerprint event", "")
	}
	for _, event := range dpiEvents {
		device, err := agentnetprobe.DpiEventToDiscoveredDevice(event, opts)
		add(device, err, "Skipping invalid netprobe DPI event", passive)
	}
	for _, snapshot := range processSnapshots {
		device, err := agentnetprobe.ProcessSnapshotToDiscoveredDevice(snapshot, opts)
		add(device, err, "Skipping invalid netprobe process snapshot", passive)
	}
	return updates
}

func buildNetprobeResultsPayloads(
	updates []map[string]any,
	maxPayloadBytes int,
	maxStreamBytes int,
) ([][]byte, int, error) {
	if len(updates) == 0 {
		return nil, 0, nil
	}
	if maxPayloadBytes <= 0 {
		maxPayloadBytes = netprobeResultsPayloadMaxBytes
	}
	if maxStreamBytes <= 0 {
		maxStreamBytes = maxPayloadBytes
	}

	var (
		payloads    [][]byte
		batch       []byte
		batchCount  int
		streamBytes int
		skipped     int
		streamFull  bool
	)

	flush := func() {
		if batchCount == 0 {
			return
		}

		payload := append(append([]byte(nil), batch...), ']')
		if streamBytes+len(payload) > maxStreamBytes {
			skipped += batchCount
			streamFull = true
			batch = nil
			batchCount = 0

			return
		}

		payloads = append(payloads, payload)
		streamBytes += len(payload)
		batch = nil
		batchCount = 0
	}

	for _, update := range updates {
		if update == nil {
			continue
		}
		if streamFull {
			skipped++
			continue
		}

		updateJSON, err := json.Marshal(update)
		if err != nil {
			return nil, skipped, err
		}
		if len(updateJSON)+2 > maxPayloadBytes {
			skipped++
			continue
		}

		extraBytes := len(updateJSON) + 1
		if batchCount > 0 {
			extraBytes++
		}
		if batchCount > 0 && len(batch)+extraBytes > maxPayloadBytes {
			flush()
			if streamFull {
				skipped++
				continue
			}
		}

		if batchCount == 0 {
			batch = []byte{'['}
		} else {
			batch = append(batch, ',')
		}
		batch = append(batch, updateJSON...)
		batchCount++
	}

	flush()

	return payloads, skipped, nil
}

func netprobeDiscoverySource(metadata map[string]string) string {
	if metadata != nil {
		if source := strings.TrimSpace(metadata["discovery_source"]); source != "" {
			return source
		}
		if source := strings.TrimSpace(metadata["source"]); source != "" {
			return source
		}
	}

	return string(models.DiscoverySourcePassiveNetprobe)
}

func (p *PushLoop) pushMapperInterfaces(ctx context.Context) bool {
	return p.pushMapperFamily(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainInterfaces(1000)
		},
		buildMapperInterfacePayload,
		discoveryMapperInterfaces,
		"mapper_interfaces",
		"interface_count",
	)
}

func (p *PushLoop) pushMapperTopology(ctx context.Context) bool {
	return p.pushMapperFamily(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainTopology(1000)
		},
		buildMapperTopologyPayload,
		discoveryMapperTopology,
		"mapper_topology",
		"topology_count",
	)
}

func (p *PushLoop) pushMapperFamily(
	ctx context.Context,
	drain func(*MapperService) ([]map[string]interface{}, bool),
	buildPayload func([]map[string]interface{}, string, string) ([]byte, error),
	kind discoveryKind,
	serviceType string,
	countField string,
) bool {
	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	updateCount := 0
	sent := p.pushDiscovery(kind, agentID, partition,
		func() [][]byte {
			if mapperSvc == nil {
				return nil
			}
			updates, ok := drain(mapperSvc)
			if !ok || len(updates) == 0 {
				return nil
			}
			payload, err := buildPayload(updates, agentID, partition)
			if err != nil {
				p.logger.Error().Err(err).Msg("Failed to build mapper payload")
				return nil
			}
			if len(payload) == 0 {
				return nil
			}
			updateCount = len(updates)
			return [][]byte{payload}
		},
		func(data []byte) bool {
			return p.streamDiscoveryPayload(ctx, data, "mapper", serviceType)
		})
	if sent && updateCount > 0 {
		p.logger.Info().Int(countField, updateCount).Msg("Streamed mapper results to gateway")
	}
	return sent
}
