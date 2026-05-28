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
	"errors"
	"os"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const maxBumblebeeSpoolBytes = 16 * 1024 * 1024

type BumblebeeSpoolService struct {
	agentID   string
	spoolPath string
}

func NewBumblebeeSpoolService(agentID string, cfg *BumblebeeStatusConfig) *BumblebeeSpoolService {
	return &BumblebeeSpoolService{
		agentID:   agentID,
		spoolPath: cfg.effectiveSpoolPath(),
	}
}

func (s *BumblebeeSpoolService) Start(context.Context) error { return nil }
func (s *BumblebeeSpoolService) Stop(context.Context) error  { return nil }
func (s *BumblebeeSpoolService) Name() string                { return bumblebee.ServiceName }
func (s *BumblebeeSpoolService) StatusServiceType() string   { return bumblebee.ServiceType }
func (s *BumblebeeSpoolService) StatusSource() string        { return bumblebee.SourceResults }
func (s *BumblebeeSpoolService) UpdateConfig(*models.Config) error {
	return nil
}

func (s *BumblebeeSpoolService) GetStatus(context.Context) (*proto.StatusResponse, error) {
	data, err := os.ReadFile(s.spoolPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s.notScannedStatus(), nil
		}
		return nil, err
	}
	if len(data) > maxBumblebeeSpoolBytes {
		return nil, errors.New("bumblebee spool payload exceeds size budget")
	}

	data = ensureBumblebeeAgentID(data, s.agentID)

	return &proto.StatusResponse{
		Available:   true,
		Message:     data,
		ServiceName: bumblebee.ServiceName,
		ServiceType: bumblebee.ServiceType,
	}, nil
}

func (s *BumblebeeSpoolService) notScannedStatus() *proto.StatusResponse {
	now := time.Now().UTC()
	payload := bumblebee.ScanPayload{
		SchemaVersion: bumblebee.SchemaVersion,
		AgentID:       s.agentID,
		RunID:         "bumblebee-not-scanned",
		State:         "not_scanned",
		CoverageState: "not_scanned",
		LastScanAt:    now,
		Findings:      []bumblebee.Finding{},
		Metadata: map[string]any{
			"spool_path": s.spoolPath,
			"reason":     "spool_not_found",
		},
	}

	data, _ := json.Marshal(payload)

	return &proto.StatusResponse{
		Available:   false,
		Message:     data,
		ServiceName: bumblebee.ServiceName,
		ServiceType: bumblebee.ServiceType,
	}
}

func ensureBumblebeeAgentID(data []byte, agentID string) []byte {
	if agentID == "" {
		return data
	}

	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}
	if value, ok := payload["agent_id"].(string); ok && value != "" {
		return data
	}

	payload["agent_id"] = agentID
	updated, err := json.Marshal(payload)
	if err != nil {
		return data
	}

	return updated
}
