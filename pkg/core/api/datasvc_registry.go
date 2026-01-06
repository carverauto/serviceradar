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

package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type dataSvcInstanceView struct {
	InstanceID    string    `json:"instance_id"`
	Endpoint      string    `json:"endpoint"`
	Available     bool      `json:"available"`
	LastHeartbeat time.Time `json:"last_heartbeat"`
}

// handleListDataSvcInstances returns the list of registered datasvc instances.
// This is used by the admin UI to display available datasvc instances for edge onboarding.
// DataSvc instances register themselves as services via PushStatus, just like gateways/agents.
func (s *APIServer) handleListDataSvcInstances(w http.ResponseWriter, r *http.Request) {
	if s.dbService == nil {
		writeError(w, "Database service not available", http.StatusServiceUnavailable)
		return
	}

	const listInstancesQuery = `
		SELECT DISTINCT ON (service_name)
			service_name,
			gateway_id,
			agent_id,
			available,
			details,
			timestamp
		FROM service_status
		WHERE service_type = 'datasvc'
		ORDER BY service_name, timestamp DESC`

	rows, err := s.dbService.ExecuteQuery(r.Context(), listInstancesQuery)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to query datasvc instances")
		writeError(w, "failed to list datasvc instances", http.StatusInternalServerError)
		return
	}

	instances := make([]dataSvcInstanceView, 0, len(rows))
	for _, row := range rows {
		instanceID := selectInstanceID(row)
		if instanceID == "" {
			continue
		}

		inst := dataSvcInstanceView{
			InstanceID:    instanceID,
			Endpoint:      extractDatasvcEndpoint(asString(row["details"])),
			Available:     asBool(row["available"]),
			LastHeartbeat: asTimeValue(row["timestamp"]),
		}

		instances = append(instances, inst)
	}

	s.logger.Debug().
		Int("count", len(instances)).
		Msg("Returning datasvc instances")

	s.writeJSON(w, http.StatusOK, instances)
}

func selectInstanceID(row map[string]interface{}) string {
	ids := []string{
		asString(row["service_name"]),
		asString(row["agent_id"]),
		asString(row["gateway_id"]),
	}
	for _, candidate := range ids {
		if trimmed := strings.TrimSpace(candidate); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func extractDatasvcEndpoint(details string) string {
	if strings.TrimSpace(details) == "" {
		return ""
	}

	type payload struct {
		Endpoint string `json:"endpoint"`
	}

	var body payload
	if err := json.Unmarshal([]byte(details), &body); err == nil {
		return strings.TrimSpace(body.Endpoint)
	}

	var generic map[string]interface{}
	if err := json.Unmarshal([]byte(details), &generic); err == nil {
		if endpoint, ok := generic["endpoint"].(string); ok {
			return strings.TrimSpace(endpoint)
		}
	}

	return ""
}

func asString(value interface{}) string {
	switch v := value.(type) {
	case string:
		return v
	case []byte:
		return string(v)
	case fmt.Stringer:
		return v.String()
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", v)
	}
}

func asBool(value interface{}) bool {
	switch v := value.(type) {
	case bool:
		return v
	case int64:
		return v != 0
	case int32:
		return v != 0
	case uint64:
		return v != 0
	case uint32:
		return v != 0
	case string:
		trimmed := strings.TrimSpace(v)
		return trimmed == "1" || strings.EqualFold(trimmed, "true")
	case []byte:
		return asBool(string(v))
	default:
		return false
	}
}

func asTimeValue(value interface{}) time.Time {
	switch v := value.(type) {
	case time.Time:
		return v.UTC()
	case string:
		if parsed, err := time.Parse(time.RFC3339Nano, v); err == nil {
			return parsed.UTC()
		}
	case []byte:
		if parsed, err := time.Parse(time.RFC3339Nano, string(v)); err == nil {
			return parsed.UTC()
		}
	}
	return time.Time{}
}
