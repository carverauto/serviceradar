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

package agent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

const (
	WorkloadIdentityServiceName = "workload-identity"
	WorkloadIdentityServiceType = "workload-identity"
	WorkloadIdentitySource      = "workload-identity"

	defaultWorkloadIdentitySnapshotPath = "/var/lib/serviceradar/workload-identity/spool/latest.json"
	maxWorkloadIdentitySnapshotBytes    = 15 * 1024 * 1024
)

var (
	errWorkloadIdentitySnapshotNotRegular = errors.New("workload identity snapshot is not a regular file")
	errWorkloadIdentitySnapshotEmpty      = errors.New("workload identity snapshot is empty")
	errWorkloadIdentitySnapshotTooLarge   = errors.New("workload identity snapshot exceeds maximum size")
	errWorkloadIdentitySnapshotChanged    = errors.New("workload identity snapshot changed during read")
)

type workloadIdentityFileSignature struct {
	path         string
	semanticHash [sha256.Size]byte
}

func (s workloadIdentityFileSignature) zero() bool {
	return s.path == "" && s.semanticHash == [sha256.Size]byte{}
}

func (p *PushLoop) pushWorkloadIdentity(ctx context.Context) bool {
	snapshotPath := p.workloadIdentitySnapshotPath()
	payload, sig, err := readWorkloadIdentitySnapshot(snapshotPath, maxWorkloadIdentitySnapshotBytes)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			p.logger.Warn().Err(err).Str("path", snapshotPath).Msg("Failed to read workload identity snapshot")
		}
		return false
	}

	if !p.shouldForwardWorkloadIdentity(sig) {
		return false
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()
	status := &proto.GatewayServiceStatus{
		ServiceName:  WorkloadIdentityServiceName,
		Available:    true,
		Message:      payload,
		ServiceType:  WorkloadIdentityServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       WorkloadIdentitySource,
		KvStoreId:    kvStoreID,
	}

	chunk := &proto.GatewayStatusChunk{
		Services:    []*proto.GatewayServiceStatus{status},
		GatewayId:   gatewayID,
		AgentId:     agentID,
		Timestamp:   time.Now().UnixNano(),
		Partition:   partition,
		SourceIp:    p.getSourceIP(),
		Version:     runtimeMetadata.Version,
		Hostname:    runtimeMetadata.Hostname,
		Os:          runtimeMetadata.Os,
		Arch:        runtimeMetadata.Arch,
		ChunkIndex:  0,
		TotalChunks: 1,
		IsFinal:     true,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, []*proto.GatewayStatusChunk{chunk})
	if err != nil {
		p.logger.Error().Err(err).Int("snapshot_bytes", len(payload)).Msg("Failed to stream workload identity snapshot")
		return false
	}

	if !resp.GetReceived() {
		p.logger.Warn().Int("snapshot_bytes", len(payload)).Msg("Gateway did not acknowledge workload identity snapshot")
		return false
	}

	p.commitWorkloadIdentitySignature(sig)
	p.logger.Info().Int("snapshot_bytes", len(payload)).Msg("Streamed workload identity snapshot to gateway")

	return true
}

func (p *PushLoop) workloadIdentitySnapshotPath() string {
	p.server.mu.RLock()
	configDir := p.server.configDir
	p.server.mu.RUnlock()

	if configDir == "" {
		return defaultWorkloadIdentitySnapshotPath
	}

	overridePath := filepath.Join(configDir, "workload-identity-snapshot.path")
	if bytes, err := os.ReadFile(overridePath); err == nil {
		if path := stringTrimSpaceBytes(bytes); path != "" {
			return path
		}
	}

	return defaultWorkloadIdentitySnapshotPath
}

func readWorkloadIdentitySnapshot(path string, maxBytes int64) ([]byte, workloadIdentityFileSignature, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, workloadIdentityFileSignature{}, err
	}
	if !info.Mode().IsRegular() {
		return nil, workloadIdentityFileSignature{}, errWorkloadIdentitySnapshotNotRegular
	}
	if info.Size() <= 0 {
		return nil, workloadIdentityFileSignature{}, errWorkloadIdentitySnapshotEmpty
	}
	if info.Size() > maxBytes {
		return nil, workloadIdentityFileSignature{}, errWorkloadIdentitySnapshotTooLarge
	}

	payload, err := os.ReadFile(path)
	if err != nil {
		return nil, workloadIdentityFileSignature{}, err
	}
	if int64(len(payload)) != info.Size() {
		// The producer publishes by atomic rename, so this should be rare. Skip this
		// cycle instead of forwarding a signature that does not describe the bytes.
		return nil, workloadIdentityFileSignature{}, errWorkloadIdentitySnapshotChanged
	}

	return payload, workloadIdentityFileSignature{
		path:         path,
		semanticHash: workloadIdentitySemanticHash(payload),
	}, nil
}

func workloadIdentitySemanticHash(payload []byte) [sha256.Size]byte {
	normalized, err := normalizeWorkloadIdentitySnapshot(payload)
	if err != nil {
		return sha256.Sum256(payload)
	}

	return sha256.Sum256(normalized)
}

func normalizeWorkloadIdentitySnapshot(payload []byte) ([]byte, error) {
	var snapshot map[string]any

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&snapshot); err != nil {
		return nil, err
	}

	delete(snapshot, "observed_at_unix_nano")

	if identities, ok := snapshot["identities"].([]any); ok {
		sort.SliceStable(identities, func(i, j int) bool {
			return workloadIdentitySortKey(identities[i]) < workloadIdentitySortKey(identities[j])
		})
		snapshot["identities"] = identities
	}

	return json.Marshal(snapshot)
}

func workloadIdentitySortKey(value any) string {
	lookup, ok := value.(map[string]any)
	if !ok {
		return workloadIdentityJSONKey(value)
	}

	identity, _ := lookup["identity"].(map[string]any)
	parts := []string{
		stringValue(lookup["container_id"]),
		stringValue(identity["container_id"]),
		stringValue(identity["pod_uid"]),
		stringValue(identity["pod_namespace"]),
		stringValue(identity["pod_name"]),
		stringValue(identity["container_name"]),
		stringValue(identity["image"]),
		stringValue(identity["image_ref"]),
	}

	key := strings.Join(parts, "\x00")
	if strings.Trim(key, "\x00") != "" {
		return key
	}

	return workloadIdentityJSONKey(value)
}

func stringValue(value any) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return text
	}

	return workloadIdentityJSONKey(value)
}

func workloadIdentityJSONKey(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return ""
	}

	return string(data)
}

func (p *PushLoop) shouldForwardWorkloadIdentity(sig workloadIdentityFileSignature) bool {
	p.workloadIdentityMu.Lock()
	defer p.workloadIdentityMu.Unlock()

	if sig.zero() {
		return false
	}

	return p.lastWorkloadIdentityFile != sig
}

func (p *PushLoop) commitWorkloadIdentitySignature(sig workloadIdentityFileSignature) {
	p.workloadIdentityMu.Lock()
	defer p.workloadIdentityMu.Unlock()

	p.lastWorkloadIdentityFile = sig
}

func stringTrimSpaceBytes(bytes []byte) string {
	start := 0
	end := len(bytes)
	for start < end && (bytes[start] == ' ' || bytes[start] == '\n' || bytes[start] == '\r' || bytes[start] == '\t') {
		start++
	}
	for end > start && (bytes[end-1] == ' ' || bytes[end-1] == '\n' || bytes[end-1] == '\r' || bytes[end-1] == '\t') {
		end--
	}

	return string(bytes[start:end])
}
