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
	"encoding/json"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	monitoringpb "github.com/carverauto/serviceradar/proto"
)

type bumblebeeConfigEnvelope struct {
	Bumblebee *bumblebeeConfigPayload `json:"bumblebee"`
}

type bumblebeeConfigPayload struct {
	Enabled bool                         `json:"enabled"`
	AgentID string                       `json:"agent_id,omitempty"`
	Catalog *bumblebee.CatalogAssignment `json:"catalog,omitempty"`
}

func parseGatewayBumblebeeConfig(configJSON []byte) (*bumblebeeConfigPayload, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var envelope bumblebeeConfigEnvelope
	if err := json.Unmarshal(configJSON, &envelope); err != nil {
		return nil, err
	}

	if envelope.Bumblebee == nil {
		return nil, nil
	}

	return envelope.Bumblebee, nil
}

func bumblebeeConfigFromProto(cfg *monitoringpb.BumblebeeConfig) *bumblebeeConfigPayload {
	if cfg == nil {
		return nil
	}

	payload := &bumblebeeConfigPayload{
		Enabled: cfg.GetEnabled(),
		AgentID: cfg.GetAgentId(),
	}

	if catalog := cfg.GetCatalog(); catalog != nil {
		payload.Catalog = &bumblebee.CatalogAssignment{
			SchemaVersion:  catalog.GetSchemaVersion(),
			SnapshotRef:    catalog.GetSnapshotRef(),
			CatalogVersion: catalog.GetCatalogVersion(),
			SourceRevision: catalog.GetSourceRevision(),
			ObjectKey:      catalog.GetObjectKey(),
			SHA256:         catalog.GetSha256(),
			SizeBytes:      catalog.GetSizeBytes(),
		}
	}

	return payload
}

func resolveGatewayBumblebeeConfig(
	protoConfig *monitoringpb.BumblebeeConfig,
	configJSON []byte,
) (*bumblebeeConfigPayload, error) {
	if cfg := bumblebeeConfigFromProto(protoConfig); cfg != nil {
		return cfg, nil
	}

	return parseGatewayBumblebeeConfig(configJSON)
}
