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
	"net/http"
	"time"

	proton "github.com/timeplus-io/proton-go-driver/v2"
)

type dataSvcInstanceView struct {
	InstanceID    string    `json:"instance_id"`
	Endpoint      string    `json:"endpoint"`
	Available     bool      `json:"available"`
	LastHeartbeat time.Time `json:"last_heartbeat"`
}

// handleListDataSvcInstances returns the list of registered datasvc instances.
// This is used by the admin UI to display available datasvc instances for edge onboarding.
// DataSvc instances register themselves as services via ReportStatus, just like pollers/agents.
func (s *APIServer) handleListDataSvcInstances(w http.ResponseWriter, r *http.Request) {
	if s.dbService == nil {
		writeError(w, "Database service not available", http.StatusServiceUnavailable)
		return
	}

	// Query services table for service_type="datasvc"
	// Parse endpoint and availability from the config JSON field
	// Note: services is a STREAM table, so we can't use FINAL
	// Return empty list for now as datasvc registration is not fully implemented
	// (requires SPIFFE support in datasvc core_registration.go)
	query := `
		SELECT
			'' as instance_id,
			'' as endpoint,
			false as available,
			to_datetime('1970-01-01 00:00:00') as last_heartbeat
		WHERE false
	`

	connRaw, err := s.dbService.GetStreamingConnection()
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get database connection")
		writeError(w, "failed to get database connection", http.StatusInternalServerError)
		return
	}

	// Type assert to proton.Conn to access Query method
	conn, ok := connRaw.(proton.Conn)
	if !ok {
		s.logger.Error().Msg("Database connection is not a valid proton connection")
		writeError(w, "invalid database connection type", http.StatusInternalServerError)
		return
	}

	rows, err := conn.Query(r.Context(), query)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to query datasvc instances")
		writeError(w, "failed to list datasvc instances", http.StatusInternalServerError)
		return
	}
	defer func() {
		_ = rows.Close()
	}()

	var instances []dataSvcInstanceView

	for rows.Next() {
		var inst dataSvcInstanceView
		if err := rows.Scan(&inst.InstanceID, &inst.Endpoint, &inst.Available, &inst.LastHeartbeat); err != nil {
			s.logger.Error().Err(err).Msg("Failed to scan datasvc instance")
			continue
		}
		instances = append(instances, inst)
	}

	if err := rows.Err(); err != nil {
		s.logger.Error().Err(err).Msg("Error iterating datasvc instances")
		writeError(w, "error reading datasvc instances", http.StatusInternalServerError)
		return
	}

	s.logger.Debug().
		Int("count", len(instances)).
		Msg("Returning datasvc instances")

	s.writeJSON(w, http.StatusOK, instances)
}
