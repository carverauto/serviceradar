package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

const (
	serviceTypePoller  = "poller"
	serviceTypeAgent   = "agent"
	serviceTypeChecker = "checker"
)

// GetPoller retrieves a poller by ID.
func (r *ServiceRegistry) GetPoller(ctx context.Context, pollerID string) (*RegisteredPoller, error) {
	if r.useCNPGReads() {
		return r.getPollerCNPG(ctx, pollerID)
	}

	query := fmt.Sprintf(`SELECT
		poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, agent_count, checker_count
	FROM table(pollers)
	WHERE poller_id = '%s'
	ORDER BY _tp_time DESC
	LIMIT 1`, escapeLiteral(pollerID))

	row := r.db.Conn.QueryRow(ctx, query)

	var (
		poller       RegisteredPoller
		metadataJSON string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		statusStr    string
		sourceStr    string
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
	poller.Metadata = decodeServiceMetadata([]byte(metadataJSON))

	return &poller, nil
}

// GetAgent retrieves an agent by ID.
func (r *ServiceRegistry) GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error) {
	if r.useCNPGReads() {
		return r.getAgentCNPG(ctx, agentID)
	}

	query := fmt.Sprintf(`SELECT
		agent_id, poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, checker_count
	FROM table(agents)
	WHERE agent_id = '%s'
	ORDER BY _tp_time DESC
	LIMIT 1`, escapeLiteral(agentID))

	row := r.db.Conn.QueryRow(ctx, query)

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
	agent.Metadata = decodeServiceMetadata([]byte(metadataJSON))

	return &agent, nil
}

// GetChecker retrieves a checker by ID.
func (r *ServiceRegistry) GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error) {
	if r.useCNPGReads() {
		return r.getCheckerCNPG(ctx, checkerID)
	}

	query := fmt.Sprintf(`SELECT
		checker_id, agent_id, poller_id, checker_kind, component_id,
		status, registration_source, first_registered, first_seen, last_seen,
		metadata, spiffe_identity, created_by
	FROM table(checkers)
	WHERE checker_id = '%s'
	ORDER BY _tp_time DESC
	LIMIT 1`, escapeLiteral(checkerID))

	row := r.db.Conn.QueryRow(ctx, query)

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
	checker.Metadata = decodeServiceMetadata([]byte(metadataJSON))

	return &checker, nil
}

// ListPollers retrieves all pollers matching filter.
func (r *ServiceRegistry) ListPollers(ctx context.Context, filter *ServiceFilter) ([]*RegisteredPoller, error) {
	if filter == nil {
		filter = &ServiceFilter{}
	}

	if r.useCNPGReads() {
		return r.listPollersCNPG(ctx, filter)
	}

	query := `SELECT
		poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, agent_count, checker_count
	FROM pollers
	FINAL
	WHERE 1=1`

	// Apply status filter
	if len(filter.Statuses) > 0 {
		statusList := make([]string, len(filter.Statuses))
		for i, s := range filter.Statuses {
			statusList[i] = string(s)
		}
		query += fmt.Sprintf(` AND status IN (%s)`, quoteStringSlice(statusList))
	}

	// Apply source filter
	if len(filter.Sources) > 0 {
		sourceList := make([]string, len(filter.Sources))
		for i, s := range filter.Sources {
			sourceList[i] = string(s)
		}
		query += fmt.Sprintf(` AND registration_source IN (%s)`, quoteStringSlice(sourceList))
	}

	query += ` ORDER BY first_registered DESC`

	if filter.Limit > 0 {
		query += fmt.Sprintf(` LIMIT %d`, filter.Limit)
	}

	if filter.Offset > 0 {
		query += fmt.Sprintf(` OFFSET %d`, filter.Offset)
	}

	rows, err := r.db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to list pollers: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

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
		poller.Metadata = decodeServiceMetadata([]byte(metadataJSON))

		pollers = append(pollers, &poller)
	}

	return pollers, nil
}

// ListAgentsByPoller retrieves all agents under a poller.
func (r *ServiceRegistry) ListAgentsByPoller(ctx context.Context, pollerID string) ([]*RegisteredAgent, error) {
	if r.useCNPGReads() {
		return r.listAgentsByPollerCNPG(ctx, pollerID)
	}

	query := fmt.Sprintf(`SELECT
		agent_id, poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, checker_count
	FROM agents
	FINAL
	WHERE poller_id = '%s'
	ORDER BY first_registered DESC`, escapeLiteral(pollerID))

	rows, err := r.db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to list agents: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

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
		agent.Metadata = decodeServiceMetadata([]byte(metadataJSON))

		agents = append(agents, &agent)
	}

	return agents, nil
}

// ListCheckersByAgent retrieves all checkers under an agent.
func (r *ServiceRegistry) ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error) {
	if r.useCNPGReads() {
		return r.listCheckersByAgentCNPG(ctx, agentID)
	}

	query := fmt.Sprintf(`SELECT
		checker_id, agent_id, poller_id, checker_kind, component_id,
		status, registration_source, first_registered, first_seen, last_seen,
		metadata, spiffe_identity, created_by
	FROM checkers
	FINAL
	WHERE agent_id = '%s'
	ORDER BY first_registered DESC`, escapeLiteral(agentID))

	rows, err := r.db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to list checkers: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

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
		checker.Metadata = decodeServiceMetadata([]byte(metadataJSON))

		checkers = append(checkers, &checker)
	}

	return checkers, nil
}

// UpdateServiceStatus updates the status of a service.
func (r *ServiceRegistry) UpdateServiceStatus(ctx context.Context, serviceType string, serviceID string, status ServiceStatus) error {
	var execErr error

	switch serviceType {
	case serviceTypePoller:
		poller, err := r.GetPoller(ctx, serviceID)
		if err != nil {
			return err
		}
		poller.Status = status

		metadataJSON, _ := json.Marshal(poller.Metadata)

		execErr = r.db.Conn.Exec(ctx,
			`INSERT INTO pollers (
				poller_id, component_id, status, registration_source,
				first_registered, first_seen, last_seen, metadata,
				spiffe_identity, created_by, agent_count, checker_count
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			poller.PollerID,
			poller.ComponentID,
			string(poller.Status),
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

		if execErr == nil {
			if err := r.upsertCNPGPoller(ctx, poller); err != nil {
				return err
			}
		}

	case serviceTypeAgent:
		agent, err := r.GetAgent(ctx, serviceID)
		if err != nil {
			return err
		}
		agent.Status = status

		metadataJSON, _ := json.Marshal(agent.Metadata)

		execErr = r.db.Conn.Exec(ctx,
			`INSERT INTO agents (
				agent_id, poller_id, component_id, status, registration_source,
				first_registered, first_seen, last_seen, metadata,
				spiffe_identity, created_by, checker_count
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			agent.AgentID,
			agent.PollerID,
			agent.ComponentID,
			string(agent.Status),
			string(agent.RegistrationSource),
			agent.FirstRegistered,
			agent.FirstSeen,
			agent.LastSeen,
			string(metadataJSON),
			agent.SPIFFEIdentity,
			agent.CreatedBy,
			agent.CheckerCount,
		)

		if execErr == nil {
			if err := r.upsertCNPGAgent(ctx, agent); err != nil {
				return err
			}
		}

	case serviceTypeChecker:
		checker, err := r.GetChecker(ctx, serviceID)
		if err != nil {
			return err
		}
		checker.Status = status

		metadataJSON, _ := json.Marshal(checker.Metadata)

		execErr = r.db.Conn.Exec(ctx,
			`INSERT INTO checkers (
				checker_id, agent_id, poller_id, checker_kind, component_id,
				status, registration_source, first_registered, first_seen, last_seen,
				metadata, spiffe_identity, created_by
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			checker.CheckerID,
			checker.AgentID,
			checker.PollerID,
			checker.CheckerKind,
			checker.ComponentID,
			string(checker.Status),
			string(checker.RegistrationSource),
			checker.FirstRegistered,
			checker.FirstSeen,
			checker.LastSeen,
			string(metadataJSON),
			checker.SPIFFEIdentity,
			checker.CreatedBy,
		)

		if execErr == nil {
			if err := r.upsertCNPGChecker(ctx, checker); err != nil {
				return err
			}
		}

	default:
		return fmt.Errorf("%w: %s", ErrUnknownServiceType, serviceType)
	}

	if execErr != nil {
		return fmt.Errorf("failed to update service status: %w", execErr)
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
	if r.useCNPGReads() {
		return r.isKnownPollerCNPG(ctx, pollerID)
	}

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
	query := fmt.Sprintf(`SELECT COUNT(*) FROM pollers
			  FINAL
			  WHERE poller_id = '%s' AND status IN ('pending', 'active')`, escapeLiteral(pollerID))

	var count uint64
	row := r.db.Conn.QueryRow(ctx, query)
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
	if r.useCNPGReads() {
		r.refreshPollerCacheCNPG(ctx)
		return
	}

	query := `SELECT poller_id FROM pollers
			  FINAL
			  WHERE status IN ('pending', 'active')`

	rows, err := r.db.Conn.Query(ctx, query)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to refresh poller cache")
		return
	}
	defer func() {
		_ = rows.Close()
	}()

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

// updatePollerStatusByLastSeen is a helper function that updates poller statuses based on last seen time.
func (r *ServiceRegistry) updatePollerStatusByLastSeen(
	ctx context.Context,
	threshold time.Duration,
	filterStatus ServiceStatus,
	targetStatus ServiceStatus,
	successMsg, errorMsg string,
) (int, error) {
	cutoff := time.Now().UTC().Add(-threshold)
	count := 0

	pollers, err := r.ListPollers(ctx, &ServiceFilter{
		Statuses: []ServiceStatus{filterStatus},
	})
	if err != nil {
		return 0, err
	}

	for _, poller := range pollers {
		if poller.LastSeen != nil && poller.LastSeen.Before(cutoff) {
			if err := r.UpdateServiceStatus(ctx, serviceTypePoller, poller.PollerID, targetStatus); err != nil {
				r.logger.Warn().Err(err).Str("poller_id", poller.PollerID).Msg(errorMsg)
			} else {
				count++
				r.logger.Info().
					Str("poller_id", poller.PollerID).
					Time("last_seen", *poller.LastSeen).
					Msg(successMsg)
			}
		}
	}

	return count, nil
}

// MarkInactive marks services as inactive if they haven't reported within threshold.
func (r *ServiceRegistry) MarkInactive(ctx context.Context, threshold time.Duration) (int, error) {
	return r.updatePollerStatusByLastSeen(
		ctx,
		threshold,
		ServiceStatusActive,
		ServiceStatusInactive,
		"Marked poller inactive",
		"Failed to mark poller inactive",
	)
}

// ArchiveInactive archives services that have been inactive for longer than retention period.
func (r *ServiceRegistry) ArchiveInactive(ctx context.Context, retentionPeriod time.Duration) (int, error) {
	// For now, we'll just mark them as revoked rather than deleting
	// In the future, could move to separate archive table
	return r.updatePollerStatusByLastSeen(
		ctx,
		retentionPeriod,
		ServiceStatusInactive,
		ServiceStatusRevoked,
		"Archived poller",
		"Failed to archive poller",
	)
}

func (r *ServiceRegistry) getPollerCNPG(ctx context.Context, pollerID string) (*RegisteredPoller, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
			poller_id,
			component_id,
			status,
			registration_source,
			first_registered,
			first_seen,
			last_seen,
			metadata,
			spiffe_identity,
			created_by,
			agent_count,
			checker_count
		FROM pollers
		WHERE poller_id = $1
		LIMIT 1`, pollerID)
	if err != nil {
		return nil, fmt.Errorf("failed to query poller: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	if !rows.Next() {
		return nil, fmt.Errorf("poller not found: %w", db.ErrFailedToQuery)
	}

	var (
		poller       RegisteredPoller
		statusStr    string
		sourceStr    string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		metadataRaw  []byte
		agentCount   int
		checkerCount int
	)

	if err := rows.Scan(
		&poller.PollerID,
		&poller.ComponentID,
		&statusStr,
		&sourceStr,
		&poller.FirstRegistered,
		&firstSeenPtr,
		&lastSeenPtr,
		&metadataRaw,
		&poller.SPIFFEIdentity,
		&poller.CreatedBy,
		&agentCount,
		&checkerCount,
	); err != nil {
		return nil, fmt.Errorf("failed to scan poller: %w", err)
	}

	poller.Status = ServiceStatus(statusStr)
	poller.RegistrationSource = RegistrationSource(sourceStr)
	poller.FirstSeen = firstSeenPtr
	poller.LastSeen = lastSeenPtr
	poller.AgentCount = agentCount
	poller.CheckerCount = checkerCount
	poller.Metadata = decodeServiceMetadata(metadataRaw)

	return &poller, rows.Err()
}

func (r *ServiceRegistry) getAgentCNPG(ctx context.Context, agentID string) (*RegisteredAgent, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
			agent_id,
			poller_id,
			component_id,
			status,
			registration_source,
			first_registered,
			first_seen,
			last_seen,
			metadata,
			spiffe_identity,
			created_by,
			checker_count
		FROM agents
		WHERE agent_id = $1
		LIMIT 1`, agentID)
	if err != nil {
		return nil, fmt.Errorf("failed to query agent: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	if !rows.Next() {
		return nil, fmt.Errorf("agent not found: %w", db.ErrFailedToQuery)
	}

	var (
		agent        RegisteredAgent
		statusStr    string
		sourceStr    string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		metadataRaw  []byte
	)

	if err := rows.Scan(
		&agent.AgentID,
		&agent.PollerID,
		&agent.ComponentID,
		&statusStr,
		&sourceStr,
		&agent.FirstRegistered,
		&firstSeenPtr,
		&lastSeenPtr,
		&metadataRaw,
		&agent.SPIFFEIdentity,
		&agent.CreatedBy,
		&agent.CheckerCount,
	); err != nil {
		return nil, fmt.Errorf("failed to scan agent: %w", err)
	}

	agent.Status = ServiceStatus(statusStr)
	agent.RegistrationSource = RegistrationSource(sourceStr)
	agent.FirstSeen = firstSeenPtr
	agent.LastSeen = lastSeenPtr
	agent.Metadata = decodeServiceMetadata(metadataRaw)

	return &agent, rows.Err()
}

func (r *ServiceRegistry) getCheckerCNPG(ctx context.Context, checkerID string) (*RegisteredChecker, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
			checker_id,
			agent_id,
			poller_id,
			checker_kind,
			component_id,
			status,
			registration_source,
			first_registered,
			first_seen,
			last_seen,
			metadata,
			spiffe_identity,
			created_by
		FROM checkers
		WHERE checker_id = $1
		LIMIT 1`, checkerID)
	if err != nil {
		return nil, fmt.Errorf("failed to query checker: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	if !rows.Next() {
		return nil, fmt.Errorf("checker not found: %w", db.ErrFailedToQuery)
	}

	var (
		checker      RegisteredChecker
		statusStr    string
		sourceStr    string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		metadataRaw  []byte
	)

	if err := rows.Scan(
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
		&metadataRaw,
		&checker.SPIFFEIdentity,
		&checker.CreatedBy,
	); err != nil {
		return nil, fmt.Errorf("failed to scan checker: %w", err)
	}

	checker.Status = ServiceStatus(statusStr)
	checker.RegistrationSource = RegistrationSource(sourceStr)
	checker.FirstSeen = firstSeenPtr
	checker.LastSeen = lastSeenPtr
	checker.Metadata = decodeServiceMetadata(metadataRaw)

	return &checker, rows.Err()
}

func (r *ServiceRegistry) listPollersCNPG(ctx context.Context, filter *ServiceFilter) ([]*RegisteredPoller, error) {
	builder := strings.Builder{}
	builder.WriteString(`
SELECT
	poller_id,
	component_id,
	status,
	registration_source,
	first_registered,
	first_seen,
	last_seen,
	metadata,
	spiffe_identity,
	created_by,
	agent_count,
	checker_count
FROM pollers
WHERE 1=1`)

	args := make([]interface{}, 0)
	argPos := 1

	if len(filter.Statuses) > 0 {
		placeholders := make([]string, len(filter.Statuses))
		for i, s := range filter.Statuses {
			args = append(args, string(s))
			placeholders[i] = fmt.Sprintf("$%d", argPos)
			argPos++
		}
		builder.WriteString(` AND status IN (` + strings.Join(placeholders, ",") + `)`)
	}

	if len(filter.Sources) > 0 {
		placeholders := make([]string, len(filter.Sources))
		for i, s := range filter.Sources {
			args = append(args, string(s))
			placeholders[i] = fmt.Sprintf("$%d", argPos)
			argPos++
		}
		builder.WriteString(` AND registration_source IN (` + strings.Join(placeholders, ",") + `)`)
	}

	builder.WriteString(` ORDER BY first_registered DESC`)

	if filter.Limit > 0 {
		args = append(args, filter.Limit)
		builder.WriteString(fmt.Sprintf(" LIMIT $%d", argPos))
		argPos++
	}

	if filter.Offset > 0 {
		args = append(args, filter.Offset)
		builder.WriteString(fmt.Sprintf(" OFFSET $%d", argPos))
	}

	rows, err := r.queryCNPGRows(ctx, builder.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("failed to list pollers: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	var pollers []*RegisteredPoller

	for rows.Next() {
		var (
			poller       RegisteredPoller
			statusStr    string
			sourceStr    string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			metadataRaw  []byte
			agentCount   int
			checkerCount int
		)

		if err := rows.Scan(
			&poller.PollerID,
			&poller.ComponentID,
			&statusStr,
			&sourceStr,
			&poller.FirstRegistered,
			&firstSeenPtr,
			&lastSeenPtr,
			&metadataRaw,
			&poller.SPIFFEIdentity,
			&poller.CreatedBy,
			&agentCount,
			&checkerCount,
		); err != nil {
			r.logger.Error().Err(err).Msg("Error scanning poller")
			continue
		}

		poller.Status = ServiceStatus(statusStr)
		poller.RegistrationSource = RegistrationSource(sourceStr)
		poller.FirstSeen = firstSeenPtr
		poller.LastSeen = lastSeenPtr
		poller.AgentCount = agentCount
		poller.CheckerCount = checkerCount
		poller.Metadata = decodeServiceMetadata(metadataRaw)

		pollers = append(pollers, &poller)
	}

	return pollers, rows.Err()
}

func (r *ServiceRegistry) listAgentsByPollerCNPG(ctx context.Context, pollerID string) ([]*RegisteredAgent, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
			agent_id,
			poller_id,
			component_id,
			status,
			registration_source,
			first_registered,
			first_seen,
			last_seen,
			metadata,
			spiffe_identity,
			created_by,
			checker_count
		FROM agents
		WHERE poller_id = $1
		ORDER BY first_registered DESC`, pollerID)
	if err != nil {
		return nil, fmt.Errorf("failed to list agents: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	var agents []*RegisteredAgent

	for rows.Next() {
		var (
			agent        RegisteredAgent
			statusStr    string
			sourceStr    string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			metadataRaw  []byte
		)

		if err := rows.Scan(
			&agent.AgentID,
			&agent.PollerID,
			&agent.ComponentID,
			&statusStr,
			&sourceStr,
			&agent.FirstRegistered,
			&firstSeenPtr,
			&lastSeenPtr,
			&metadataRaw,
			&agent.SPIFFEIdentity,
			&agent.CreatedBy,
			&agent.CheckerCount,
		); err != nil {
			r.logger.Error().Err(err).Msg("Error scanning agent")
			continue
		}

		agent.Status = ServiceStatus(statusStr)
		agent.RegistrationSource = RegistrationSource(sourceStr)
		agent.FirstSeen = firstSeenPtr
		agent.LastSeen = lastSeenPtr
		agent.Metadata = decodeServiceMetadata(metadataRaw)

		agents = append(agents, &agent)
	}

	return agents, rows.Err()
}

func (r *ServiceRegistry) listCheckersByAgentCNPG(ctx context.Context, agentID string) ([]*RegisteredChecker, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
			checker_id,
			agent_id,
			poller_id,
			checker_kind,
			component_id,
			status,
			registration_source,
			first_registered,
			first_seen,
			last_seen,
			metadata,
			spiffe_identity,
			created_by
		FROM checkers
		WHERE agent_id = $1
		ORDER BY first_registered DESC`, agentID)
	if err != nil {
		return nil, fmt.Errorf("failed to list checkers: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	var checkers []*RegisteredChecker

	for rows.Next() {
		var (
			checker      RegisteredChecker
			statusStr    string
			sourceStr    string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			metadataRaw  []byte
		)

		if err := rows.Scan(
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
			&metadataRaw,
			&checker.SPIFFEIdentity,
			&checker.CreatedBy,
		); err != nil {
			r.logger.Error().Err(err).Msg("Error scanning checker")
			continue
		}

		checker.Status = ServiceStatus(statusStr)
		checker.RegistrationSource = RegistrationSource(sourceStr)
		checker.FirstSeen = firstSeenPtr
		checker.LastSeen = lastSeenPtr
		checker.Metadata = decodeServiceMetadata(metadataRaw)

		checkers = append(checkers, &checker)
	}

	return checkers, rows.Err()
}

func (r *ServiceRegistry) isKnownPollerCNPG(ctx context.Context, pollerID string) (bool, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT COUNT(*)
		FROM pollers
		WHERE poller_id = $1
		  AND status IN ('pending', 'active')`, pollerID)
	if err != nil {
		return false, fmt.Errorf("failed to check poller: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	if !rows.Next() {
		return false, fmt.Errorf("failed to check poller: %w", db.ErrFailedToQuery)
	}

	var count int
	if err := rows.Scan(&count); err != nil {
		return false, fmt.Errorf("failed to scan poller count: %w", err)
	}

	return count > 0, rows.Err()
}

func (r *ServiceRegistry) refreshPollerCacheCNPG(ctx context.Context) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT poller_id
		FROM pollers
		WHERE status IN ('pending', 'active')`)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to refresh poller cache (cnpg)")
		return
	}
	defer func() {
		_ = rows.Close()
	}()

	newCache := make(map[string]bool)
	for rows.Next() {
		var pollerID string
		if err := rows.Scan(&pollerID); err != nil {
			continue
		}
		newCache[pollerID] = true
	}

	if err := rows.Err(); err != nil {
		r.logger.Warn().Err(err).Msg("Error while refreshing poller cache (cnpg)")
		return
	}

	r.pollerCache = newCache
	r.cacheExpiry = time.Now().Add(pollerCacheTTL)

	r.logger.Debug().
		Int("cache_size", len(newCache)).
		Msg("Refreshed poller cache (cnpg)")
}

func decodeServiceMetadata(raw []byte) map[string]string {
	if len(raw) == 0 {
		return nil
	}

	var metadata map[string]string
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return nil
	}

	return metadata
}

func escapeLiteral(value string) string {
	return strings.ReplaceAll(value, "'", "''")
}

func quoteStringSlice(values []string) string {
	if len(values) == 0 {
		return ""
	}

	quoted := make([]string, 0, len(values))
	for _, v := range values {
		if v == "" {
			continue
		}
		quoted = append(quoted, fmt.Sprintf("'%s'", escapeLiteral(v)))
	}

	return strings.Join(quoted, ", ")
}
