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
	"strconv"
	"strings"
	"time"

	snmpchecker "github.com/carverauto/serviceradar/go/pkg/agent/snmp"
	"github.com/carverauto/serviceradar/proto"
)

type snmpMetricResult struct {
	Target string
	Host   string
	Metric string
	OID    string
	// Raw walk-row index; empty for a scalar get. Carried explicitly because
	// the only other place it survives is InterfaceUID, which folds it together
	// with a derived ifIndex and cannot be told apart from one downstream.
	OIDIndex     string
	Value        interface{}
	RawValue     interface{}
	Timestamp    time.Time
	DataType     string
	Scale        float64
	Delta        bool
	Kind         string
	Temporality  string
	IsMonotonic  bool
	CounterWidth int
	IfIndex      *int
	InterfaceUID string
	// Collecting profile UUID, copied from the pushed SNMPConfig. Metadata
	// only: device_snmp_facts uses it for provenance, and it must not become a
	// series-key tag.
	ProfileID string
}

func (p *PushLoop) pushSNMPMetrics(ctx context.Context) bool {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	snmpSvc := p.server.snmpService
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()

	if snmpSvc == nil || !snmpSvc.IsEnabled() {
		return false
	}

	// 1. Get metadata (HostIP, OID configs)
	statuses, err := snmpSvc.GetTargetStatuses(ctx)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to get SNMP target status for metadata")
		return false
	}

	// 2. Drain buffered metrics
	metrics, err := snmpSvc.DrainMetrics(ctx)
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to drain SNMP metrics")
		return false
	}

	if len(metrics) == 0 {
		return false
	}

	// 3. Build results for all drained points
	results := p.buildSNMPDrainedResults(statuses, metrics, snmpSvc.GetProfileID())
	if len(results) == 0 {
		return false
	}

	messageBytes, err := marshalSNMPMetricEnvelope(results, metricEnvelopeContext{
		AgentID:   agentID,
		GatewayID: gatewayID,
		Partition: partition,
		KvStoreID: kvStoreID,
	})
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to marshal SNMP metric envelope")
		return false
	}
	p.publishAddonMetricFeed("snmp", messageBytes)

	status := &proto.GatewayServiceStatus{
		ServiceName:  "snmp",
		Available:    true,
		Message:      messageBytes,
		ServiceType:  "snmp",
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       "snmp-metrics",
		KvStoreId:    kvStoreID,
	}

	chunk := &proto.GatewayStatusChunk{
		Services:    []*proto.GatewayServiceStatus{status},
		GatewayId:   gatewayID,
		AgentId:     agentID,
		Timestamp:   time.Now().UnixNano(),
		Partition:   partition,
		SourceIp:    p.getSourceIP(),
		IsFinal:     true,
		ChunkIndex:  0,
		TotalChunks: 1,
		KvStoreId:   kvStoreID,
		Version:     runtimeMetadata.Version,
		Hostname:    runtimeMetadata.Hostname,
		Os:          runtimeMetadata.Os,
		Arch:        runtimeMetadata.Arch,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, []*proto.GatewayStatusChunk{chunk})
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream SNMP metrics to gateway")
		return false
	}

	if resp.Received {
		p.logger.Info().Int("result_count", len(results)).Msg("Successfully streamed SNMP metrics to gateway")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge SNMP metrics stream")
	return false
}

func (p *PushLoop) buildSNMPDrainedResults(
	statuses map[string]snmpchecker.TargetStatus,
	metrics map[string][]snmpchecker.DataPoint,
	profileID string,
) []snmpMetricResult {
	results := make([]snmpMetricResult, 0)

	for key, points := range metrics {
		parts := strings.SplitN(key, "|", 2)
		if len(parts) != 2 {
			continue
		}
		targetName := parts[0]
		oidName := parts[1]

		status, ok := statuses[targetName]
		if !ok {
			continue
		}

		oidConfigs := make(map[string]snmpchecker.OIDConfig)
		if status.Target != nil {
			for _, oid := range status.Target.OIDs {
				oidConfigs[oid.Name] = oid
			}
		}

		oidConfig, ok := lookupOIDConfig(oidConfigs, oidName)
		oidValue := ""
		dataType := ""
		scale := 1.0
		delta := false
		if ok {
			oidValue = oidConfig.OID
			dataType = string(oidConfig.DataType)
			scale = oidConfig.Scale
			delta = oidConfig.Delta
		}

		metricName, parsedUID := parseSNMPMetricName(oidName)

		for _, point := range points {
			pointDataType := dataType
			if point.DataType != "" {
				pointDataType = string(point.DataType)
			}

			pointScale := scale
			if point.Scale != 0 {
				pointScale = point.Scale
			}

			pointDelta := delta
			if !point.Delta {
				pointDelta = false
			}

			pointOID := instanceOID(oidValue, point.OIDIndex)
			ifIndex := ifIndexForSNMPPoint(pointOID, oidValue, point)

			result := snmpMetricResult{
				Target:       targetName,
				Host:         status.HostIP,
				Metric:       metricName,
				OID:          pointOID,
				OIDIndex:     point.OIDIndex,
				Value:        point.Value,
				RawValue:     point.RawValue,
				Timestamp:    point.Timestamp,
				DataType:     pointDataType,
				Scale:        pointScale,
				Delta:        pointDelta,
				Kind:         point.Kind,
				Temporality:  point.Temporality,
				IsMonotonic:  point.IsMonotonic,
				CounterWidth: point.CounterWidth,
				InterfaceUID: interfaceUIDForSNMPPoint(parsedUID, ifIndex, point.OIDIndex),
				ProfileID:    profileID,
			}

			if ifIndex != nil {
				result.IfIndex = ifIndex
			}

			results = append(results, result)
		}
	}

	return results
}

func lookupOIDConfig(oidConfigs map[string]snmpchecker.OIDConfig, oidName string) (snmpchecker.OIDConfig, bool) {
	if cfg, ok := oidConfigs[oidName]; ok {
		return cfg, true
	}

	base, _ := parseSNMPMetricName(oidName)
	if base != "" && base != oidName {
		if cfg, ok := oidConfigs[base]; ok {
			return cfg, true
		}
	}

	return snmpchecker.OIDConfig{}, false
}

func instanceOID(configOID, index string) string {
	configOID = strings.TrimSpace(configOID)
	index = strings.TrimSpace(index)

	if configOID == "" {
		return ""
	}

	if index == "" {
		return configOID
	}

	return strings.TrimSuffix(configOID, ".") + "." + strings.TrimPrefix(index, ".")
}

func ifIndexForSNMPPoint(instance, configOID string, point snmpchecker.DataPoint) *int {
	if isInterfaceTableOID(configOID) || isInterfaceTableOID(instance) {
		if idx := parseIfIndexToken(point.OIDIndex); idx != nil {
			return idx
		}

		return parseIfIndexFromOID(instance)
	}

	if point.OIDIndex == "" {
		return parseIfIndexFromOID(configOID)
	}

	return nil
}

func interfaceUIDForSNMPPoint(parsedUID string, ifIndex *int, oidIndex string) string {
	if ifIndex != nil {
		return "ifindex:" + strconv.Itoa(*ifIndex)
	}

	if parsedUID != "" {
		return parsedUID
	}

	if oidIndex != "" {
		return "index:" + oidIndex
	}

	return ""
}

func isInterfaceTableOID(oid string) bool {
	oid = strings.TrimPrefix(strings.TrimSpace(oid), ".")

	return strings.HasPrefix(oid, "1.3.6.1.2.1.2.2.1.") ||
		strings.HasPrefix(oid, "1.3.6.1.2.1.31.1.1.1.")
}

func parseIfIndexToken(token string) *int {
	token = strings.TrimSpace(token)
	if token == "" || strings.Contains(token, ".") {
		return nil
	}

	value, err := strconv.Atoi(token)
	if err != nil || value <= 0 {
		return nil
	}

	return &value
}

func parseSNMPMetricName(raw string) (string, string) {
	if raw == "" {
		return "", ""
	}

	parts := strings.SplitN(raw, "::", 2)
	if len(parts) == 2 {
		return parts[0], parts[1]
	}

	return raw, ""
}

func parseIfIndexFromOID(oid string) *int {
	oid = strings.TrimSpace(oid)
	if oid == "" {
		return nil
	}

	parts := strings.Split(oid, ".")
	if len(parts) == 0 {
		return nil
	}

	last := parts[len(parts)-1]
	if last == "" {
		return nil
	}

	value, err := strconv.Atoi(last)
	if err != nil || value <= 0 {
		return nil
	}

	return &value
}
