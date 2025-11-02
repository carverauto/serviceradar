package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// GetPoller retrieves a poller by ID.
func (r *ServiceRegistry) GetPoller(ctx context.Context, pollerID string) (*RegisteredPoller, error) {
	query := `SELECT
		poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, agent_count, checker_count
	FROM table(pollers)
	WHERE poller_id = ?
	ORDER BY _tp_time DESC
	LIMIT 1`

	row := r.db.Conn.QueryRow(ctx, query, pollerID)

	var (
		poller        RegisteredPoller
		metadataJSON  string
		firstSeenPtr  *time.Time
		lastSeenPtr   *time.Time
		statusStr     string
		sourceStr     string
	)

	err := row.Scan(
		&poller.PollerID,
		&poller.ComponentID,
		&statusStr,
		&sourceStr,
		&poller.FirstRegistered,
		&firstSeenPtr,
		&lastSeenPtr,
		&metadataJSON,
		&poller.SPIFFEIdentity,
		&poller.CreatedBy,
		&poller.AgentCount,
		&poller.CheckerCount,
	)

	if err != nil {
		return nil, fmt.Errorf("poller not found: %w", err)
	}

	poller.Status = ServiceStatus(statusStr)
	poller.RegistrationSource = RegistrationSource(sourceStr)
	poller.FirstSeen = firstSeenPtr
	poller.LastSeen = lastSeenPtr

	// Unmarshal metadata
	if metadataJSON != "" {
		var metadata map[string]string
		if err := json.Unmarshal([]byte(metadataJSON), &metadata); err == nil {
			poller.Metadata = metadata
		}
	}

	return &poller, nil
}

// GetAgent retrieves an agent by ID.
func (r *ServiceRegistry) GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error) {
	query := `SELECT
		agent_id, poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, checker_count
	FROM table(agents)
	WHERE agent_id = ?
	ORDER BY _tp_time DESC
	LIMIT 1`

	row := r.db.Conn.QueryRow(ctx, query, agentID)

	var (
		agent        RegisteredAgent
		metadataJSON string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		statusStr    string
		sourceStr    string
	)

	err := row.Scan(
		&agent.AgentID,
		&agent.PollerID,
		&agent.ComponentID,
		&statusStr,
		&sourceStr,
		&agent.FirstRegistered,
		&firstSeenPtr,
		&lastSeenPtr,
		&metadataJSON,
		&agent.SPIFFEIdentity,
		&agent.CreatedBy,
		&agent.CheckerCount,
	)

	if err != nil {
		return nil, fmt.Errorf("agent not found: %w", err)
	}

	agent.Status = ServiceStatus(statusStr)
	agent.RegistrationSource = RegistrationSource(sourceStr)
	agent.FirstSeen = firstSeenPtr
	agent.LastSeen = lastSeenPtr

	// Unmarshal metadata
	if metadataJSON != "" {
		var metadata map[string]string
		if err := json.Unmarshal([]byte(metadataJSON), &metadata); err == nil {
			agent.Metadata = metadata
		}
	}

	return &agent, nil
}

// GetChecker retrieves a checker by ID.
func (r *ServiceRegistry) GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error) {
	query := `SELECT
		checker_id, agent_id, poller_id, checker_kind, component_id,
		status, registration_source, first_registered, first_seen, last_seen,
		metadata, spiffe_identity, created_by
	FROM table(checkers)
	WHERE checker_id = ?
	ORDER BY _tp_time DESC
	LIMIT 1`

	row := r.db.Conn.QueryRow(ctx, query, checkerID)

	var (
		checker      RegisteredChecker
		metadataJSON string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		statusStr    string
		sourceStr    string
	)

	err := row.Scan(
		&checker.CheckerID,
		&checker.AgentID,
		&checker.PollerID,
		&checker.CheckerKind,
		&checker.ComponentID,
		&statusStr,
		&sourceStr,
		&checker.FirstRegistered,
		&firstSeenPtr,
		&lastSeenPtr,
		&metadataJSON,
		&checker.SPIFFEIdentity,
		&checker.CreatedBy,
	)

	if err != nil {
		return nil, fmt.Errorf("checker not found: %w", err)
	}

	checker.Status = ServiceStatus(statusStr)
	checker.RegistrationSource = RegistrationSource(sourceStr)
	checker.FirstSeen = firstSeenPtr
	checker.LastSeen = lastSeenPtr

	// Unmarshal metadata
	if metadataJSON != "" {
		var metadata map[string]string
		if err := json.Unmarshal([]byte(metadataJSON), &metadata); err == nil {
			checker.Metadata = metadata
		}
	}

	return &checker, nil
}

// ListPollers retrieves all pollers matching filter.
func (r *ServiceRegistry) ListPollers(ctx context.Context, filter *ServiceFilter) ([]*RegisteredPoller, error) {
	query := `SELECT
		poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, agent_count, checker_count
	FROM pollers
	FINAL
	WHERE 1=1`

	args := []interface{}{}

	// Apply status filter
	if len(filter.Statuses) > 0 {
		statusList := make([]string, len(filter.Statuses))
		for i, s := range filter.Statuses {
			statusList[i] = string(s)
		}
		query += ` AND status IN (?)`
		args = append(args, statusList)
	}

	// Apply source filter
	if len(filter.Sources) > 0 {
		sourceList := make([]string, len(filter.Sources))
		for i, s := range filter.Sources {
			sourceList[i] = string(s)
		}
		query += ` AND registration_source IN (?)`
		args = append(args, sourceList)
	}

	query += ` ORDER BY first_registered DESC`

	if filter.Limit > 0 {
		query += ` LIMIT ?`
		args = append(args, filter.Limit)
	}

	if filter.Offset > 0 {
		query += ` OFFSET ?`
		args = append(args, filter.Offset)
	}

	rows, err := r.db.Conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to list pollers: %w", err)
	}
	defer rows.Close()

	var pollers []*RegisteredPoller

	for rows.Next() {
		var (
			poller       RegisteredPoller
			metadataJSON string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			statusStr    string
			sourceStr    string
		)

		err := rows.Scan(
			&poller.PollerID,
			&poller.ComponentID,
			&statusStr,
			&sourceStr,
			&poller.FirstRegistered,
			&firstSeenPtr,
			&lastSeenPtr,
			&metadataJSON,
			&poller.SPIFFEIdentity,
			&poller.CreatedBy,
			&poller.AgentCount,
			&poller.CheckerCount,
		)

		if err != nil {
			r.logger.Error().Err(err).Msg("Error scanning poller")
			continue
		}

		poller.Status = ServiceStatus(statusStr)
		poller.RegistrationSource = RegistrationSource(sourceStr)
		poller.FirstSeen = firstSeenPtr
		poller.LastSeen = lastSeenPtr

		// Unmarshal metadata
		if metadataJSON != "" {
			var metadata map[string]string
			if err := json.Unmarshal([]byte(metadataJSON), &metadata); err == nil {
				poller.Metadata = metadata
			}
		}

		pollers = append(pollers, &poller)
	}

	return pollers, nil
}

// ListAgentsByPoller retrieves all agents under a poller.
func (r *ServiceRegistry) ListAgentsByPoller(ctx context.Context, pollerID string) ([]*RegisteredAgent, error) {
	query := `SELECT
		agent_id, poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, checker_count
	FROM agents
	FINAL
	WHERE poller_id = ?
	ORDER BY first_registered DESC`

	rows, err := r.db.Conn.Query(ctx, query, pollerID)
	if err != nil {
		return nil, fmt.Errorf("failed to list agents: %w", err)
	}
	defer rows.Close()

	var agents []*RegisteredAgent

	for rows.Next() {
		var (
			agent        RegisteredAgent
			metadataJSON string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			statusStr    string
			sourceStr    string
		)

		err := rows.Scan(
			&agent.AgentID,
			&agent.PollerID,
			&agent.ComponentID,
			&statusStr,
			&sourceStr,
			&agent.FirstRegistered,
			&firstSeenPtr,
			&lastSeenPtr,
			&metadataJSON,
			&agent.SPIFFEIdentity,
			&agent.CreatedBy,
			&agent.CheckerCount,
		)

		if err != nil {
			r.logger.Error().Err(err).Msg("Error scanning agent")
			continue
		}

		agent.Status = ServiceStatus(statusStr)
		agent.RegistrationSource = RegistrationSource(sourceStr)
		agent.FirstSeen = firstSeenPtr
		agent.LastSeen = lastSeenPtr

		// Unmarshal metadata
		if metadataJSON != "" {
			var metadata map[string]string
			if err := json.Unmarshal([]byte(metadataJSON), &metadata); err == nil {
				agent.Metadata = metadata
			}
		}

		agents = append(agents, &agent)
	}

	return agents, nil
}

// ListCheckersByAgent retrieves all checkers under an agent.
func (r *ServiceRegistry) ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error) {
	query := `SELECT
		checker_id, agent_id, poller_id, checker_kind, component_id,
		status, registration_source, first_registered, first_seen, last_seen,
		metadata, spiffe_identity, created_by
	FROM checkers
	FINAL
	WHERE agent_id = ?
	ORDER BY first_registered DESC`

	rows, err := r.db.Conn.Query(ctx, query, agentID)
	if err != nil {
		return nil, fmt.Errorf("failed to list checkers: %w", err)
	}
	defer rows.Close()

	var checkers []*RegisteredChecker

	for rows.Next() {
		var (
			checker      RegisteredChecker
			metadataJSON string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			statusStr    string
			sourceStr    string
		)

		err := rows.Scan(
			&checker.CheckerID,
			&checker.AgentID,
			&checker.PollerID,
			&checker.CheckerKind,
			&checker.ComponentID,
			&statusStr,
			&sourceStr,
			&checker.FirstRegistered,
			&firstSeenPtr,
			&lastSeenPtr,
			&metadataJSON,
			&checker.SPIFFEIdentity,
			&checker.CreatedBy,
		)

		if err != nil {
			r.logger.Error().Err(err).Msg("Error scanning checker")
			continue
		}

		checker.Status = ServiceStatus(statusStr)
		checker.RegistrationSource = RegistrationSource(sourceStr)
		checker.FirstSeen = firstSeenPtr
		checker.LastSeen = lastSeenPtr

		// Unmarshal metadata
		if metadataJSON != "" {
			var metadata map[string]string
			if err := json.Unmarshal([]byte(metadataJSON), &metadata); err == nil {
				checker.Metadata = metadata
			}
		}

		checkers = append(checkers, &checker)
	}

	return checkers, nil
}

// UpdateServiceStatus updates the status of a service.
func (r *ServiceRegistry) UpdateServiceStatus(ctx context.Context, serviceType string, serviceID string, status ServiceStatus) error {
	var query string
	var service interface{}
	var err error

	// Get current service
	switch serviceType {
	case "poller":
		service, err = r.GetPoller(ctx, serviceID)
		if err != nil {
			return err
		}
		poller := service.(*RegisteredPoller)

		query = `INSERT INTO pollers (
			poller_id, component_id, status, registration_source,
			first_registered, first_seen, last_seen, metadata,
			spiffe_identity, created_by, agent_count, checker_count
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

		metadataJSON, _ := json.Marshal(poller.Metadata)

		err = r.db.Conn.Exec(ctx, query,
			poller.PollerID,
			poller.ComponentID,
			string(status),
			string(poller.RegistrationSource),
			poller.FirstRegistered,
			poller.FirstSeen,
			poller.LastSeen,
			string(metadataJSON),
			poller.SPIFFEIdentity,
			poller.CreatedBy,
			poller.AgentCount,
			poller.CheckerCount,
		)

	case "agent":
		service, err = r.GetAgent(ctx, serviceID)
		if err != nil {
			return err
		}
		agent := service.(*RegisteredAgent)

		query = `INSERT INTO agents (
			agent_id, poller_id, component_id, status, registration_source,
			first_registered, first_seen, last_seen, metadata,
			spiffe_identity, created_by, checker_count
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

		metadataJSON, _ := json.Marshal(agent.Metadata)

		err = r.db.Conn.Exec(ctx, query,
			agent.AgentID,
			agent.PollerID,
			agent.ComponentID,
			string(status),
			string(agent.RegistrationSource),
			agent.FirstRegistered,
			agent.FirstSeen,
			agent.LastSeen,
			string(metadataJSON),
			agent.SPIFFEIdentity,
			agent.CreatedBy,
			agent.CheckerCount,
		)

	case "checker":
		service, err = r.GetChecker(ctx, serviceID)
		if err != nil {
			return err
		}
		checker := service.(*RegisteredChecker)

		query = `INSERT INTO checkers (
			checker_id, agent_id, poller_id, checker_kind, component_id,
			status, registration_source, first_registered, first_seen, last_seen,
			metadata, spiffe_identity, created_by
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

		metadataJSON, _ := json.Marshal(checker.Metadata)

		err = r.db.Conn.Exec(ctx, query,
			checker.CheckerID,
			checker.AgentID,
			checker.PollerID,
			checker.CheckerKind,
			checker.ComponentID,
			string(status),
			string(checker.RegistrationSource),
			checker.FirstRegistered,
			checker.FirstSeen,
			checker.LastSeen,
			string(metadataJSON),
			checker.SPIFFEIdentity,
			checker.CreatedBy,
		)

	default:
		return fmt.Errorf("unknown service type: %s", serviceType)
	}

	if err != nil {
		return fmt.Errorf("failed to update service status: %w", err)
	}

	r.logger.Info().
		Str("service_type", serviceType).
		Str("service_id", serviceID).
		Str("new_status", string(status)).
		Msg("Updated service status")

	return nil
}

// IsKnownPoller checks if a poller is registered and active/pending.
// This replaces the logic in pkg/core/pollers.go
func (r *ServiceRegistry) IsKnownPoller(ctx context.Context, pollerID string) (bool, error) {
	// Check cache first
	r.pollerCacheMu.RLock()
	if time.Now().Before(r.cacheExpiry) {
		known, exists := r.pollerCache[pollerID]
		r.pollerCacheMu.RUnlock()
		if exists {
			return known, nil
		}
	}
	r.pollerCacheMu.RUnlock()

	// Query database
	query := `SELECT COUNT(*) FROM pollers
			  FINAL
			  WHERE poller_id = ? AND status IN ('pending', 'active')`

	var count int
	row := r.db.Conn.QueryRow(ctx, query, pollerID)
	if err := row.Scan(&count); err != nil {
		return false, fmt.Errorf("failed to check poller: %w", err)
	}

	known := count > 0

	// Update cache
	r.pollerCacheMu.Lock()
	if time.Now().After(r.cacheExpiry) {
		// Refresh entire cache
		r.refreshPollerCache(ctx)
	} else {
		r.pollerCache[pollerID] = known
	}
	r.pollerCacheMu.Unlock()

	return known, nil
}

// refreshPollerCache refreshes the entire poller cache.
// Must be called with pollerCacheMu locked.
func (r *ServiceRegistry) refreshPollerCache(ctx context.Context) {
	query := `SELECT poller_id FROM pollers
			  FINAL
			  WHERE status IN ('pending', 'active')`

	rows, err := r.db.Conn.Query(ctx, query)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to refresh poller cache")
		return
	}
	defer rows.Close()

	newCache := make(map[string]bool)
	for rows.Next() {
		var pollerID string
		if err := rows.Scan(&pollerID); err != nil {
			continue
		}
		newCache[pollerID] = true
	}

	r.pollerCache = newCache
	r.cacheExpiry = time.Now().Add(pollerCacheTTL)

	r.logger.Debug().
		Int("cache_size", len(newCache)).
		Msg("Refreshed poller cache")
}

// MarkInactive marks services as inactive if they haven't reported within threshold.
func (r *ServiceRegistry) MarkInactive(ctx context.Context, threshold time.Duration) (int, error) {
	cutoff := time.Now().UTC().Add(-threshold)
	count := 0

	// Mark inactive pollers
	pollers, err := r.ListPollers(ctx, &ServiceFilter{
		Statuses: []ServiceStatus{ServiceStatusActive},
	})
	if err != nil {
		return 0, err
	}

	for _, poller := range pollers {
		if poller.LastSeen != nil && poller.LastSeen.Before(cutoff) {
			if err := r.UpdateServiceStatus(ctx, "poller", poller.PollerID, ServiceStatusInactive); err != nil {
				r.logger.Warn().Err(err).Str("poller_id", poller.PollerID).Msg("Failed to mark poller inactive")
			} else {
				count++
				r.logger.Info().
					Str("poller_id", poller.PollerID).
					Time("last_seen", *poller.LastSeen).
					Msg("Marked poller inactive")
			}
		}
	}

	return count, nil
}

// ArchiveInactive archives services that have been inactive for longer than retention period.
func (r *ServiceRegistry) ArchiveInactive(ctx context.Context, retentionPeriod time.Duration) (int, error) {
	cutoff := time.Now().UTC().Add(-retentionPeriod)
	count := 0

	// For now, we'll just mark them as revoked rather than deleting
	// In the future, could move to separate archive table

	pollers, err := r.ListPollers(ctx, &ServiceFilter{
		Statuses: []ServiceStatus{ServiceStatusInactive},
	})
	if err != nil {
		return 0, err
	}

	for _, poller := range pollers {
		if poller.LastSeen != nil && poller.LastSeen.Before(cutoff) {
			if err := r.UpdateServiceStatus(ctx, "poller", poller.PollerID, ServiceStatusRevoked); err != nil {
				r.logger.Warn().Err(err).Str("poller_id", poller.PollerID).Msg("Failed to archive poller")
			} else {
				count++
				r.logger.Info().
					Str("poller_id", poller.PollerID).
					Time("last_seen", *poller.LastSeen).
					Msg("Archived poller")
			}
		}
	}

	return count, nil
}
