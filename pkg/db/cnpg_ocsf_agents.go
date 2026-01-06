/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// UpsertOCSFAgent inserts or updates an OCSF agent.
// This is the write path for agent registration - reads are handled by SRQL.
func (db *DB) UpsertOCSFAgent(ctx context.Context, agent *models.OCSFAgentRecord) error {
	if agent == nil || !db.cnpgConfigured() {
		return nil
	}

	// Serialize JSONB fields
	policiesJSON, metadataJSON, err := agent.ToJSONFields()
	if err != nil {
		return fmt.Errorf("failed to serialize OCSF agent JSONB fields: %w", err)
	}

	// Set modification time
	now := time.Now().UTC()
	agent.ModifiedTime = now

	// If first seen is not set, use now
	if agent.FirstSeenTime.IsZero() {
		agent.FirstSeenTime = now
	}
	if agent.LastSeenTime.IsZero() {
		agent.LastSeenTime = now
	}

	const query = `
	INSERT INTO ocsf_agents (
		uid, name, type_id, type, version, vendor_name, uid_alt, policies,
		gateway_id, capabilities, ip,
		first_seen_time, last_seen_time, created_time, modified_time,
		metadata
	) VALUES (
		$1, $2, $3, $4, $5, $6, $7, $8::jsonb,
		$9, $10, $11,
		$12, $13, $14, $15,
		$16::jsonb
	)
	ON CONFLICT (uid) DO UPDATE SET
		name = COALESCE(NULLIF(EXCLUDED.name, ''), ocsf_agents.name),
		type_id = CASE WHEN EXCLUDED.type_id != 0 THEN EXCLUDED.type_id ELSE ocsf_agents.type_id END,
		type = CASE WHEN EXCLUDED.type_id != 0 THEN EXCLUDED.type ELSE ocsf_agents.type END,
		version = COALESCE(NULLIF(EXCLUDED.version, ''), ocsf_agents.version),
		vendor_name = COALESCE(NULLIF(EXCLUDED.vendor_name, ''), ocsf_agents.vendor_name),
		uid_alt = COALESCE(EXCLUDED.uid_alt, ocsf_agents.uid_alt),
		policies = COALESCE(EXCLUDED.policies, ocsf_agents.policies),
		gateway_id = COALESCE(NULLIF(EXCLUDED.gateway_id, ''), ocsf_agents.gateway_id),
		capabilities = CASE
			WHEN EXCLUDED.capabilities IS NOT NULL AND array_length(EXCLUDED.capabilities, 1) > 0
			THEN (SELECT ARRAY(SELECT DISTINCT unnest(array_cat(ocsf_agents.capabilities, EXCLUDED.capabilities))))
			ELSE ocsf_agents.capabilities
		END,
		ip = COALESCE(NULLIF(EXCLUDED.ip, ''), ocsf_agents.ip),
		last_seen_time = EXCLUDED.last_seen_time,
		modified_time = EXCLUDED.modified_time,
		metadata = COALESCE(ocsf_agents.metadata, '{}'::jsonb) || COALESCE(EXCLUDED.metadata, '{}'::jsonb)`

	_, err = db.pgPool.Exec(ctx, query,
		agent.UID,
		agent.Name,
		agent.TypeID,
		agent.Type,
		agent.Version,
		agent.VendorName,
		agent.UIDAlt,
		policiesJSON,
		agent.GatewayID,
		agent.Capabilities,
		agent.IP,
		agent.FirstSeenTime,
		agent.LastSeenTime,
		agent.CreatedTime,
		agent.ModifiedTime,
		metadataJSON,
	)

	if err != nil {
		return fmt.Errorf("failed to upsert ocsf agent: %w", err)
	}

	return nil
}
