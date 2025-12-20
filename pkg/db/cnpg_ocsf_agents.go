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
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/lib/pq"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ocsf agent error sentinels
var (
	errOCSFAgentNotFound        = errors.New("ocsf agent not found")
	errFailedToQueryOCSFAgent   = errors.New("failed to query ocsf agent")
	errFailedToScanOCSFAgentRow = errors.New("failed to scan ocsf agent row")
)

// ocsfAgentsSelection is the base SELECT for querying ocsf_agents.
const ocsfAgentsSelection = `
SELECT
	uid,
	name,
	type_id,
	type,
	version,
	vendor_name,
	uid_alt,
	policies,
	poller_id,
	capabilities,
	ip,
	first_seen_time,
	last_seen_time,
	created_time,
	modified_time,
	metadata
FROM ocsf_agents
WHERE 1=1`

// GetOCSFAgent retrieves a single OCSF agent by UID
func (db *DB) GetOCSFAgent(ctx context.Context, uid string) (*models.OCSFAgentRecord, error) {
	if !db.cnpgConfigured() {
		return nil, errOCSFAgentNotFound
	}

	query := ocsfAgentsSelection + " AND uid = $1"

	row := db.pgPool.QueryRow(ctx, query, uid)

	agent, err := scanOCSFAgentRow(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) || errors.Is(err, sql.ErrNoRows) {
			return nil, errOCSFAgentNotFound
		}
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFAgent, err)
	}

	return agent, nil
}

// ListOCSFAgents retrieves a paginated list of OCSF agents
func (db *DB) ListOCSFAgents(ctx context.Context, limit, offset int) ([]*models.OCSFAgentRecord, error) {
	if !db.cnpgConfigured() {
		return nil, nil
	}

	query := ocsfAgentsSelection + " ORDER BY last_seen_time DESC LIMIT $1 OFFSET $2"

	rows, err := db.pgPool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFAgent, err)
	}
	defer rows.Close()

	return scanOCSFAgentRows(rows)
}

// ListOCSFAgentsByPoller retrieves all OCSF agents for a specific poller
func (db *DB) ListOCSFAgentsByPoller(ctx context.Context, pollerID string) ([]*models.OCSFAgentRecord, error) {
	if !db.cnpgConfigured() {
		return nil, nil
	}

	query := ocsfAgentsSelection + " AND poller_id = $1 ORDER BY last_seen_time DESC"

	rows, err := db.pgPool.Query(ctx, query, pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFAgent, err)
	}
	defer rows.Close()

	return scanOCSFAgentRows(rows)
}

// CountOCSFAgents returns the total count of OCSF agents
func (db *DB) CountOCSFAgents(ctx context.Context) (int64, error) {
	if !db.cnpgConfigured() {
		return 0, nil
	}

	const query = `SELECT COUNT(*) FROM ocsf_agents`

	var count int64
	err := db.pgPool.QueryRow(ctx, query).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("failed to count ocsf agents: %w", err)
	}

	return count, nil
}

// UpsertOCSFAgent inserts or updates an OCSF agent
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
		poller_id, capabilities, ip,
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
		poller_id = COALESCE(NULLIF(EXCLUDED.poller_id, ''), ocsf_agents.poller_id),
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
		agent.PollerID,
		pq.Array(agent.Capabilities),
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

// scanOCSFAgentRow scans a single row into an OCSFAgentRecord
func scanOCSFAgentRow(row pgx.Row) (*models.OCSFAgentRecord, error) {
	var agent models.OCSFAgentRecord
	var policiesJSON, metadataJSON []byte
	var capabilities []string
	var firstSeen, lastSeen, created, modified sql.NullTime
	var name, agentType, version, vendorName, uidAlt, pollerID, ip sql.NullString

	err := row.Scan(
		&agent.UID,
		&name,
		&agent.TypeID,
		&agentType,
		&version,
		&vendorName,
		&uidAlt,
		&policiesJSON,
		&pollerID,
		&capabilities,
		&ip,
		&firstSeen,
		&lastSeen,
		&created,
		&modified,
		&metadataJSON,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanOCSFAgentRow, err)
	}

	// Map nullable fields
	agent.Name = name.String
	agent.Type = agentType.String
	agent.Version = version.String
	agent.VendorName = vendorName.String
	agent.UIDAlt = uidAlt.String
	agent.PollerID = pollerID.String
	agent.IP = ip.String
	agent.Capabilities = capabilities

	if firstSeen.Valid {
		agent.FirstSeenTime = firstSeen.Time
	}
	if lastSeen.Valid {
		agent.LastSeenTime = lastSeen.Time
	}
	if created.Valid {
		agent.CreatedTime = created.Time
	}
	if modified.Valid {
		agent.ModifiedTime = modified.Time
	}

	// Unmarshal JSONB fields
	if len(policiesJSON) > 0 {
		if err := json.Unmarshal(policiesJSON, &agent.Policies); err != nil {
			return nil, fmt.Errorf("failed to unmarshal policies: %w", err)
		}
	}
	if len(metadataJSON) > 0 {
		if err := json.Unmarshal(metadataJSON, &agent.Metadata); err != nil {
			return nil, fmt.Errorf("failed to unmarshal metadata: %w", err)
		}
	}

	return &agent, nil
}

// scanOCSFAgentRows scans multiple rows into OCSFAgentRecords
func scanOCSFAgentRows(rows pgx.Rows) ([]*models.OCSFAgentRecord, error) {
	var agents []*models.OCSFAgentRecord

	for rows.Next() {
		var agent models.OCSFAgentRecord
		var policiesJSON, metadataJSON []byte
		var capabilities []string
		var firstSeen, lastSeen, created, modified sql.NullTime
		var name, agentType, version, vendorName, uidAlt, pollerID, ip sql.NullString

		err := rows.Scan(
			&agent.UID,
			&name,
			&agent.TypeID,
			&agentType,
			&version,
			&vendorName,
			&uidAlt,
			&policiesJSON,
			&pollerID,
			&capabilities,
			&ip,
			&firstSeen,
			&lastSeen,
			&created,
			&modified,
			&metadataJSON,
		)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToScanOCSFAgentRow, err)
		}

		// Map nullable fields
		agent.Name = name.String
		agent.Type = agentType.String
		agent.Version = version.String
		agent.VendorName = vendorName.String
		agent.UIDAlt = uidAlt.String
		agent.PollerID = pollerID.String
		agent.IP = ip.String
		agent.Capabilities = capabilities

		if firstSeen.Valid {
			agent.FirstSeenTime = firstSeen.Time
		}
		if lastSeen.Valid {
			agent.LastSeenTime = lastSeen.Time
		}
		if created.Valid {
			agent.CreatedTime = created.Time
		}
		if modified.Valid {
			agent.ModifiedTime = modified.Time
		}

		// Unmarshal JSONB fields
		if len(policiesJSON) > 0 {
			if err := json.Unmarshal(policiesJSON, &agent.Policies); err != nil {
				return nil, fmt.Errorf("failed to unmarshal policies: %w", err)
			}
		}
		if len(metadataJSON) > 0 {
			if err := json.Unmarshal(metadataJSON, &agent.Metadata); err != nil {
				return nil, fmt.Errorf("failed to unmarshal metadata: %w", err)
			}
		}

		agents = append(agents, &agent)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating ocsf agent rows: %w", err)
	}

	return agents, nil
}
