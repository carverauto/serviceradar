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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/carverauto/serviceradar/go/pkg/k8sinventory"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// K8sPublicEndpointsServiceName is the stable service_name for gateway routing.
	K8sPublicEndpointsServiceName = "k8s-public-endpoints"
	// K8sPublicEndpointsServiceType is the reserved service_type discriminator.
	K8sPublicEndpointsServiceType = "k8s_public_endpoints"
	// K8sPublicEndpointsSourceResults marks inventory as a results-class payload.
	K8sPublicEndpointsSourceResults = "results"
	// K8sPublicEndpointsSchemaVersion is stamped onto agent-forwarded envelopes when missing.
	K8sPublicEndpointsSchemaVersion = "serviceradar.k8s_public_endpoints.v1"
)

var errK8sPublicEndpointsSpoolTooLarge = errors.New("k8s public endpoints spool payload exceeds size budget")

// K8sPublicEndpointsStatusConfig configures the agent-side spool reader.
type K8sPublicEndpointsStatusConfig struct {
	Enabled   bool   `json:"enabled,omitempty"`
	SpoolDir  string `json:"spool_dir,omitempty"`
	SpoolPath string `json:"spool_path,omitempty"` // optional explicit latest.json path
	ClusterID string `json:"cluster_id,omitempty"`
}

func (c *K8sPublicEndpointsStatusConfig) effectiveSpoolPath() string {
	if c == nil {
		return k8sinventory.LatestPath(k8sinventory.DefaultSpoolDir)
	}
	if p := c.SpoolPath; p != "" {
		return p
	}
	dir := c.SpoolDir
	if dir == "" {
		dir = k8sinventory.DefaultSpoolDir
	}
	return k8sinventory.LatestPath(dir)
}

// K8sPublicEndpointsSpoolService exposes inventory snapshots via GetStatus for push_loop.
type K8sPublicEndpointsSpoolService struct {
	agentID   string
	clusterID string
	spoolPath string

	mu          sync.Mutex
	lastHash    string
	lastPayload []byte
	lastModTime int64
	lastSize    int64
}

// NewK8sPublicEndpointsSpoolService builds a spool reader for the cluster agent.
func NewK8sPublicEndpointsSpoolService(agentID string, cfg *K8sPublicEndpointsStatusConfig) *K8sPublicEndpointsSpoolService {
	if cfg == nil {
		cfg = &K8sPublicEndpointsStatusConfig{}
	}
	return &K8sPublicEndpointsSpoolService{
		agentID:   agentID,
		clusterID: cfg.ClusterID,
		spoolPath: cfg.effectiveSpoolPath(),
	}
}

func (s *K8sPublicEndpointsSpoolService) Start(context.Context) error { return nil }
func (s *K8sPublicEndpointsSpoolService) Stop(context.Context) error  { return nil }
func (s *K8sPublicEndpointsSpoolService) Name() string {
	return K8sPublicEndpointsServiceName
}
func (s *K8sPublicEndpointsSpoolService) StatusServiceType() string {
	return K8sPublicEndpointsServiceType
}
func (s *K8sPublicEndpointsSpoolService) StatusSource() string {
	return K8sPublicEndpointsSourceResults
}
func (s *K8sPublicEndpointsSpoolService) UpdateConfig(*models.Config) error { return nil }

func (s *K8sPublicEndpointsSpoolService) GetStatus(context.Context) (*proto.StatusResponse, error) {
	data, err := s.readStablePayload()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s.notReadyStatus("spool_not_found"), nil
		}
		return nil, err
	}
	if int64(len(data)) > k8sinventory.MaxSpoolPayloadBytes {
		return nil, errK8sPublicEndpointsSpoolTooLarge
	}

	return &proto.StatusResponse{
		Available:   true,
		Message:     data,
		ServiceName: K8sPublicEndpointsServiceName,
		ServiceType: K8sPublicEndpointsServiceType,
	}, nil
}

func (s *K8sPublicEndpointsSpoolService) readStablePayload() ([]byte, error) {
	info, err := os.Stat(s.spoolPath)
	if err != nil {
		return nil, err
	}
	mod := info.ModTime().UnixNano()
	size := info.Size()

	s.mu.Lock()
	if s.lastPayload != nil && s.lastModTime == mod && s.lastSize == size {
		out := append([]byte(nil), s.lastPayload...)
		s.mu.Unlock()
		return out, nil
	}
	s.mu.Unlock()

	raw, err := os.ReadFile(s.spoolPath)
	if err != nil {
		return nil, err
	}

	payload := ensureK8sPublicEndpointsEnvelope(raw, s.agentID, s.clusterID)
	sum := sha256.Sum256(payload)
	hash := hex.EncodeToString(sum[:])

	s.mu.Lock()
	s.lastHash = hash
	s.lastPayload = append([]byte(nil), payload...)
	s.lastModTime = mod
	s.lastSize = size
	s.mu.Unlock()

	return payload, nil
}

func (s *K8sPublicEndpointsSpoolService) notReadyStatus(reason string) *proto.StatusResponse {
	body := map[string]any{
		"schema_version": K8sPublicEndpointsSchemaVersion,
		"agent_id":       s.agentID,
		"cluster_id":     s.clusterID,
		"state":          "not_ready",
		"metadata": map[string]any{
			"spool_path": s.spoolPath,
			"reason":     reason,
		},
	}
	data, _ := json.Marshal(body)
	return &proto.StatusResponse{
		Available:   false,
		Message:     data,
		ServiceName: K8sPublicEndpointsServiceName,
		ServiceType: K8sPublicEndpointsServiceType,
	}
}

func ensureK8sPublicEndpointsEnvelope(data []byte, agentID, clusterID string) []byte {
	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}
	if payload["schema_version"] == nil || payload["schema_version"] == "" {
		payload["schema_version"] = K8sPublicEndpointsSchemaVersion
	}
	if agentID != "" {
		payload["agent_id"] = agentID
	}
	if clusterID != "" {
		if existing, _ := payload["cluster_id"].(string); existing == "" {
			payload["cluster_id"] = clusterID
		}
	}
	// content_hash helps gateway/agent dedup without re-shipping identical snapshots.
	if payload["content_hash"] == nil {
		// Hash raw inventory body excluding agent_id we just stamped if present only on wrap.
		sum := sha256.Sum256(data)
		payload["content_hash"] = hex.EncodeToString(sum[:])
	}
	out, err := json.Marshal(payload)
	if err != nil {
		return data
	}
	return out
}

// EffectiveSpoolDir is exported for tests / dynamic config helpers.
func (c *K8sPublicEndpointsStatusConfig) EffectiveSpoolDir() string {
	if c == nil {
		return k8sinventory.DefaultSpoolDir
	}
	if c.SpoolDir != "" {
		return c.SpoolDir
	}
	if c.SpoolPath != "" {
		return filepath.Dir(c.SpoolPath)
	}
	return k8sinventory.DefaultSpoolDir
}
