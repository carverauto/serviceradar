package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

const (
	// pollerCacheTTL defines how long to cache IsKnownPoller results
	pollerCacheTTL = 5 * time.Minute
)

// ServiceRegistry implements the ServiceManager interface.
// It manages the lifecycle and registration of all services (pollers, agents, checkers).
type ServiceRegistry struct {
	db     *db.DB
	logger zerolog.Logger

	// Cache for IsKnownPoller() - invalidated on registration changes
	pollerCacheMu sync.RWMutex
	pollerCache   map[string]bool
	cacheExpiry   time.Time
}

// NewServiceRegistry creates a new ServiceRegistry instance.
func NewServiceRegistry(database *db.DB, log logger.Logger) *ServiceRegistry {
	return &ServiceRegistry{
		db:          database,
		logger:      log.WithComponent("service-registry"),
		pollerCache: make(map[string]bool),
	}
}

// RegisterPoller explicitly registers a new poller.
func (r *ServiceRegistry) RegisterPoller(ctx context.Context, reg *PollerRegistration) error {
	now := time.Now().UTC()

	// Check if already exists
	existing, err := r.GetPoller(ctx, reg.PollerID)
	if err == nil && existing != nil {
		r.logger.Warn().
			Str("poller_id", reg.PollerID).
			Str("status", string(existing.Status)).
			Msg("Poller already registered")
		return fmt.Errorf("poller %s already registered with status %s", reg.PollerID, existing.Status)
	}

	// Marshal metadata to JSON
	metadataJSON, err := json.Marshal(reg.Metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	// Insert into pollers stream (versioned_kv) using PrepareBatch/Append/Send
	// Note: versioned_kv automatically manages _tp_time for versioning
	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO pollers (
			poller_id, component_id, status, registration_source,
			first_registered, first_seen, last_seen, metadata,
			spiffe_identity, created_by, agent_count, checker_count
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for poller registration: %w", err)
	}

	err = batch.Append(
		reg.PollerID,
		reg.ComponentID,
		string(ServiceStatusPending),
		string(reg.RegistrationSource),
		now,
		now, // first_seen
		now, // last_seen
		string(metadataJSON),
		reg.SPIFFEIdentity,
		reg.CreatedBy,
		uint32(0), // agent_count
		uint32(0), // checker_count
	)
	if err != nil {
		return fmt.Errorf("failed to append poller to batch: %w", err)
	}

	err = batch.Send()
	if err != nil {
		return fmt.Errorf("failed to register poller: %w", err)
	}

	// Emit registration event
	if err := r.emitRegistrationEvent(ctx, "registered", "poller", reg.PollerID, "", reg.RegistrationSource, reg.CreatedBy, nil); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit registration event")
	}

	// Invalidate cache
	r.invalidatePollerCache()

	r.logger.Info().
		Str("poller_id", reg.PollerID).
		Str("component_id", reg.ComponentID).
		Str("source", string(reg.RegistrationSource)).
		Msg("Registered poller")

	return nil
}

// RegisterAgent explicitly registers a new agent under a poller.
func (r *ServiceRegistry) RegisterAgent(ctx context.Context, reg *AgentRegistration) error {
	now := time.Now().UTC()

	// Skip parent validation for implicit (auto-registration) to avoid timing issues
	// with versioned_kv materialization - we know the poller just heartbeated
	if reg.RegistrationSource != RegistrationSourceImplicit {
		// Verify parent poller exists for explicit registrations
		poller, err := r.GetPoller(ctx, reg.PollerID)
		if err != nil || poller == nil {
			return fmt.Errorf("parent poller %s not found", reg.PollerID)
		}
	}

	// Check if already exists
	existing, err := r.GetAgent(ctx, reg.AgentID)
	if err == nil && existing != nil {
		r.logger.Warn().
			Str("agent_id", reg.AgentID).
			Str("status", string(existing.Status)).
			Msg("Agent already registered")
		return fmt.Errorf("agent %s already registered with status %s", reg.AgentID, existing.Status)
	}

	// Marshal metadata to JSON
	metadataJSON, err := json.Marshal(reg.Metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	// Insert into agents stream (versioned_kv) using PrepareBatch/Append/Send
	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO agents (
			agent_id, poller_id, component_id, status, registration_source,
			first_registered, first_seen, last_seen, metadata,
			spiffe_identity, created_by, checker_count
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for agent registration: %w", err)
	}

	err = batch.Append(
		reg.AgentID,
		reg.PollerID,
		reg.ComponentID,
		string(ServiceStatusPending),
		string(reg.RegistrationSource),
		now,
		now, // first_seen
		now, // last_seen
		string(metadataJSON),
		reg.SPIFFEIdentity,
		reg.CreatedBy,
		uint32(0), // checker_count
	)
	if err != nil {
		return fmt.Errorf("failed to append agent to batch: %w", err)
	}

	err = batch.Send()
	if err != nil {
		return fmt.Errorf("failed to register agent: %w", err)
	}

	// Emit registration event
	if err := r.emitRegistrationEvent(ctx, "registered", "agent", reg.AgentID, reg.PollerID, reg.RegistrationSource, reg.CreatedBy, nil); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit registration event")
	}

	r.logger.Info().
		Str("agent_id", reg.AgentID).
		Str("poller_id", reg.PollerID).
		Str("component_id", reg.ComponentID).
		Str("source", string(reg.RegistrationSource)).
		Msg("Registered agent")

	return nil
}

// RegisterChecker explicitly registers a new checker under an agent.
func (r *ServiceRegistry) RegisterChecker(ctx context.Context, reg *CheckerRegistration) error {
	now := time.Now().UTC()

	// Skip parent validation for implicit (auto-registration) to avoid timing issues
	// with versioned_kv materialization - we know the agent just reported
	if reg.RegistrationSource != RegistrationSourceImplicit {
		// Verify parent agent exists for explicit registrations
		agent, err := r.GetAgent(ctx, reg.AgentID)
		if err != nil || agent == nil {
			return fmt.Errorf("parent agent %s not found", reg.AgentID)
		}
	}

	// Check if already exists
	existing, err := r.GetChecker(ctx, reg.CheckerID)
	if err == nil && existing != nil {
		r.logger.Warn().
			Str("checker_id", reg.CheckerID).
			Str("status", string(existing.Status)).
			Msg("Checker already registered")
		return fmt.Errorf("checker %s already registered with status %s", reg.CheckerID, existing.Status)
	}

	// Marshal metadata to JSON
	metadataJSON, err := json.Marshal(reg.Metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	// Insert into checkers stream (versioned_kv) using PrepareBatch/Append/Send
	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO checkers (
			checker_id, agent_id, poller_id, checker_kind, component_id,
			status, registration_source, first_registered, first_seen, last_seen,
			metadata, spiffe_identity, created_by
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for checker registration: %w", err)
	}

	err = batch.Append(
		reg.CheckerID,
		reg.AgentID,
		reg.PollerID,
		reg.CheckerKind,
		reg.ComponentID,
		string(ServiceStatusPending),
		string(reg.RegistrationSource),
		now,
		now, // first_seen
		now, // last_seen
		string(metadataJSON),
		reg.SPIFFEIdentity,
		reg.CreatedBy,
	)
	if err != nil {
		return fmt.Errorf("failed to append checker to batch: %w", err)
	}

	err = batch.Send()
	if err != nil {
		return fmt.Errorf("failed to register checker: %w", err)
	}

	// Emit registration event
	if err := r.emitRegistrationEvent(ctx, "registered", "checker", reg.CheckerID, reg.AgentID, reg.RegistrationSource, reg.CreatedBy, nil); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit registration event")
	}

	r.logger.Info().
		Str("checker_id", reg.CheckerID).
		Str("agent_id", reg.AgentID).
		Str("poller_id", reg.PollerID).
		Str("checker_kind", reg.CheckerKind).
		Str("source", string(reg.RegistrationSource)).
		Msg("Registered checker")

	return nil
}

// RecordHeartbeat records a service heartbeat from status reports.
func (r *ServiceRegistry) RecordHeartbeat(ctx context.Context, heartbeat *ServiceHeartbeat) error {
	now := heartbeat.Timestamp
	if now.IsZero() {
		now = time.Now().UTC()
	}

	switch heartbeat.ServiceType {
	case "poller":
		return r.recordPollerHeartbeat(ctx, heartbeat.PollerID, now, heartbeat.SourceIP)
	case "agent":
		return r.recordAgentHeartbeat(ctx, heartbeat.AgentID, heartbeat.PollerID, now, heartbeat.SourceIP)
	case "checker":
		return r.recordCheckerHeartbeat(ctx, heartbeat.CheckerID, heartbeat.AgentID, heartbeat.PollerID, now)
	default:
		return fmt.Errorf("unknown service type: %s", heartbeat.ServiceType)
	}
}

// RecordBatchHeartbeats handles batch heartbeat updates efficiently.
func (r *ServiceRegistry) RecordBatchHeartbeats(ctx context.Context, heartbeats []*ServiceHeartbeat) error {
	for _, hb := range heartbeats {
		if err := r.RecordHeartbeat(ctx, hb); err != nil {
			r.logger.Warn().
				Err(err).
				Str("service_type", hb.ServiceType).
				Str("service_id", hb.ServiceID).
				Msg("Failed to record heartbeat")
		}
	}
	return nil
}

// recordPollerHeartbeat updates poller last_seen and activates if pending.
func (r *ServiceRegistry) recordPollerHeartbeat(ctx context.Context, pollerID string, timestamp time.Time, sourceIP string) error {
	// For ReplacingMergeTree, we insert a new row with updated values
	// The engine will keep the latest based on updated_at

	// First, get current state
	poller, err := r.GetPoller(ctx, pollerID)
	if err != nil {
		// Poller not registered yet - register implicitly
		if err := r.RegisterPoller(ctx, &PollerRegistration{
			PollerID:           pollerID,
			ComponentID:        pollerID,
			RegistrationSource: RegistrationSourceImplicit,
			CreatedBy:          "system",
		}); err != nil {
			return fmt.Errorf("failed to auto-register poller: %w", err)
		}
		poller, _ = r.GetPoller(ctx, pollerID)
	}

	// Determine new status
	newStatus := poller.Status
	if poller.Status == ServiceStatusPending {
		newStatus = ServiceStatusActive
	}

	// Set first_seen if this is the first report
	firstSeen := poller.FirstSeen
	if firstSeen == nil {
		firstSeen = &timestamp
	}

	// Insert updated row (versioned_kv will keep latest version)
	// Use PrepareBatch/Append/Send pattern for Proton/ClickHouse streams
	metadataJSON, _ := json.Marshal(poller.Metadata)

	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO pollers (
			poller_id, component_id, status, registration_source,
			first_registered, first_seen, last_seen, metadata,
			spiffe_identity, created_by
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for poller heartbeat: %w", err)
	}

	err = batch.Append(
		poller.PollerID,
		poller.ComponentID,
		string(newStatus),
		string(poller.RegistrationSource),
		poller.FirstRegistered,
		firstSeen,
		timestamp,
		string(metadataJSON),
		poller.SPIFFEIdentity,
		poller.CreatedBy,
	)
	if err != nil {
		return fmt.Errorf("failed to append poller heartbeat to batch: %w", err)
	}

	err = batch.Send()

	if err != nil {
		return fmt.Errorf("failed to record poller heartbeat: %w", err)
	}

	// Emit activation event if transitioned to active
	if poller.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		if err := r.emitRegistrationEvent(ctx, "activated", "poller", pollerID, "", poller.RegistrationSource, "system", nil); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("poller_id", pollerID).
			Msg("Poller activated on first heartbeat")
	}

	return nil
}

// recordAgentHeartbeat updates agent last_seen and activates if pending.
func (r *ServiceRegistry) recordAgentHeartbeat(ctx context.Context, agentID, pollerID string, timestamp time.Time, sourceIP string) error {
	// Get current state
	agent, err := r.GetAgent(ctx, agentID)
	if err != nil {
		// Agent not registered yet - register implicitly
		if err := r.RegisterAgent(ctx, &AgentRegistration{
			AgentID:            agentID,
			PollerID:           pollerID,
			ComponentID:        agentID,
			RegistrationSource: RegistrationSourceImplicit,
			CreatedBy:          "system",
		}); err != nil {
			return fmt.Errorf("failed to auto-register agent: %w", err)
		}
		agent, _ = r.GetAgent(ctx, agentID)
	}

	// Determine new status
	newStatus := agent.Status
	if agent.Status == ServiceStatusPending {
		newStatus = ServiceStatusActive
	}

	// Set first_seen if this is the first report
	firstSeen := agent.FirstSeen
	if firstSeen == nil {
		firstSeen = &timestamp
	}

	// Insert updated row (versioned_kv will keep latest version)
	// Use PrepareBatch/Append/Send pattern for Proton/ClickHouse streams
	metadataJSON, _ := json.Marshal(agent.Metadata)

	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO agents (
			agent_id, poller_id, component_id, status, registration_source,
			first_registered, first_seen, last_seen, metadata,
			spiffe_identity, created_by
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for agent heartbeat: %w", err)
	}

	err = batch.Append(
		agent.AgentID,
		agent.PollerID,
		agent.ComponentID,
		string(newStatus),
		string(agent.RegistrationSource),
		agent.FirstRegistered,
		firstSeen,
		timestamp,
		string(metadataJSON),
		agent.SPIFFEIdentity,
		agent.CreatedBy,
	)
	if err != nil {
		return fmt.Errorf("failed to append agent heartbeat to batch: %w", err)
	}

	err = batch.Send()

	if err != nil {
		return fmt.Errorf("failed to record agent heartbeat: %w", err)
	}

	// Emit activation event if transitioned to active
	if agent.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		if err := r.emitRegistrationEvent(ctx, "activated", "agent", agentID, pollerID, agent.RegistrationSource, "system", nil); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("agent_id", agentID).
			Str("poller_id", pollerID).
			Msg("Agent activated on first heartbeat")
	}

	return nil
}

// recordCheckerHeartbeat updates checker last_seen and activates if pending.
func (r *ServiceRegistry) recordCheckerHeartbeat(ctx context.Context, checkerID, agentID, pollerID string, timestamp time.Time) error {
	// Get current state
	checker, err := r.GetChecker(ctx, checkerID)
	if err != nil {
		// Checker not registered - this shouldn't happen, but handle gracefully
		r.logger.Warn().
			Str("checker_id", checkerID).
			Str("agent_id", agentID).
			Msg("Received heartbeat from unregistered checker")
		return nil
	}

	// Determine new status
	newStatus := checker.Status
	if checker.Status == ServiceStatusPending {
		newStatus = ServiceStatusActive
	}

	// Set first_seen if this is the first report
	firstSeen := checker.FirstSeen
	if firstSeen == nil {
		firstSeen = &timestamp
	}

	// Insert updated row (versioned_kv will keep latest version)
	// Use PrepareBatch/Append/Send pattern for Proton/ClickHouse streams
	metadataJSON, _ := json.Marshal(checker.Metadata)

	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO checkers (
			checker_id, agent_id, poller_id, checker_kind, component_id,
			status, registration_source, first_registered, first_seen, last_seen,
			metadata, spiffe_identity, created_by
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for checker heartbeat: %w", err)
	}

	err = batch.Append(
		checker.CheckerID,
		checker.AgentID,
		checker.PollerID,
		checker.CheckerKind,
		checker.ComponentID,
		string(newStatus),
		string(checker.RegistrationSource),
		checker.FirstRegistered,
		firstSeen,
		timestamp,
		string(metadataJSON),
		checker.SPIFFEIdentity,
		checker.CreatedBy,
	)
	if err != nil {
		return fmt.Errorf("failed to append checker heartbeat to batch: %w", err)
	}

	err = batch.Send()

	if err != nil {
		return fmt.Errorf("failed to record checker heartbeat: %w", err)
	}

	// Emit activation event if transitioned to active
	if checker.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		if err := r.emitRegistrationEvent(ctx, "activated", "checker", checkerID, agentID, checker.RegistrationSource, "system", nil); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("checker_id", checkerID).
			Str("agent_id", agentID).
			Msg("Checker activated on first heartbeat")
	}

	return nil
}

// emitRegistrationEvent emits an audit event to the service_registration_events stream.
func (r *ServiceRegistry) emitRegistrationEvent(ctx context.Context, eventType, serviceType, serviceID, parentID string, source RegistrationSource, actor string, metadata map[string]string) error {
	eventID := uuid.New().String()
	now := time.Now().UTC()

	metadataJSON, _ := json.Marshal(metadata)

	// Use PrepareBatch/Append/Send pattern for Proton/ClickHouse streams
	batch, err := r.db.Conn.PrepareBatch(ctx,
		`INSERT INTO service_registration_events (
			event_id, event_type, service_id, service_type, parent_id,
			registration_source, actor, timestamp, metadata
		)`)
	if err != nil {
		return fmt.Errorf("failed to prepare batch for registration event: %w", err)
	}

	err = batch.Append(
		eventID,
		eventType,
		serviceID,
		serviceType,
		parentID,
		string(source),
		actor,
		now,
		string(metadataJSON),
	)
	if err != nil {
		return fmt.Errorf("failed to append registration event to batch: %w", err)
	}

	return batch.Send()
}

// invalidatePollerCache clears the poller cache.
func (r *ServiceRegistry) invalidatePollerCache() {
	r.pollerCacheMu.Lock()
	defer r.pollerCacheMu.Unlock()

	r.pollerCache = make(map[string]bool)
	r.cacheExpiry = time.Time{} // Zero time = expired
}

// DeleteService permanently deletes a service from the registry.
// This should only be called for services that are no longer needed (status: revoked, inactive, or deleted).
// Returns error if service is still active or pending.
func (r *ServiceRegistry) DeleteService(ctx context.Context, serviceType, serviceID string) error {
	// Verify service is not active or pending
	var status string
	var query string
	var source string

	switch serviceType {
	case "poller":
		query = `SELECT status, registration_source FROM pollers WHERE poller_id = ? LIMIT 1`
	case "agent":
		query = `SELECT status, registration_source FROM agents WHERE agent_id = ? LIMIT 1`
	case "checker":
		query = `SELECT status, registration_source FROM checkers WHERE checker_id = ? LIMIT 1`
	default:
		return fmt.Errorf("unknown service type: %s", serviceType)
	}

	row := r.db.Conn.QueryRow(ctx, query, serviceID)
	if err := row.Scan(&status, &source); err != nil {
		return fmt.Errorf("service not found: %w", err)
	}

	if status == string(ServiceStatusActive) || status == string(ServiceStatusPending) {
		return fmt.Errorf("cannot delete service %s with status %s: mark inactive/revoked/deleted first", serviceID, status)
	}

	// Emit deletion event BEFORE deleting
	if err := r.emitRegistrationEvent(ctx, "deleted", serviceType, serviceID, "", RegistrationSource(source), "system", nil); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit deletion event")
	}

	// Hard delete from stream
	// Note: For versioned_kv streams in Timeplus/ClickHouse, we use DELETE FROM
	var deleteQuery string
	switch serviceType {
	case "poller":
		deleteQuery = `DELETE FROM pollers WHERE poller_id = ?`
	case "agent":
		deleteQuery = `DELETE FROM agents WHERE agent_id = ?`
	case "checker":
		deleteQuery = `DELETE FROM checkers WHERE checker_id = ?`
	}

	if err := r.db.Conn.Exec(ctx, deleteQuery, serviceID); err != nil {
		return fmt.Errorf("failed to delete service: %w", err)
	}

	// Invalidate cache if it's a poller
	if serviceType == "poller" {
		r.invalidatePollerCache()
	}

	r.logger.Info().
		Str("service_type", serviceType).
		Str("service_id", serviceID).
		Str("status", status).
		Msg("Service permanently deleted from registry")

	return nil
}

// PurgeInactive permanently deletes services that have been inactive, revoked, or deleted
// for longer than the retention period. This is typically called by a background job.
// Returns the number of services deleted.
func (r *ServiceRegistry) PurgeInactive(ctx context.Context, retentionPeriod time.Duration) (int, error) {
	cutoff := time.Now().UTC().Add(-retentionPeriod)

	r.logger.Info().
		Dur("retention_period", retentionPeriod).
		Time("cutoff", cutoff).
		Msg("Starting purge of inactive services")

	// Find services to purge: inactive/revoked/deleted for > retention period
	// Note: Using last_seen for inactive, first_registered for pending that never activated
	query := `SELECT service_type, service_id
              FROM (
                  SELECT 'poller' AS service_type, poller_id AS service_id, last_seen, status
                  FROM pollers
                  WHERE status IN ('inactive', 'revoked', 'deleted')
                  AND last_seen < ?

                  UNION ALL

                  SELECT 'poller', poller_id, first_registered AS last_seen, status
                  FROM pollers
                  WHERE status = 'pending'
                  AND first_seen IS NULL
                  AND first_registered < ?

                  UNION ALL

                  SELECT 'agent', agent_id, last_seen, status
                  FROM agents
                  WHERE status IN ('inactive', 'revoked', 'deleted')
                  AND last_seen < ?

                  UNION ALL

                  SELECT 'agent', agent_id, first_registered AS last_seen, status
                  FROM agents
                  WHERE status = 'pending'
                  AND first_seen IS NULL
                  AND first_registered < ?

                  UNION ALL

                  SELECT 'checker', checker_id, last_seen, status
                  FROM checkers
                  WHERE status IN ('inactive', 'revoked', 'deleted')
                  AND last_seen < ?

                  UNION ALL

                  SELECT 'checker', checker_id, first_registered AS last_seen, status
                  FROM checkers
                  WHERE status = 'pending'
                  AND first_seen IS NULL
                  AND first_registered < ?
              )`

	rows, err := r.db.Conn.Query(ctx, query, cutoff, cutoff, cutoff, cutoff, cutoff, cutoff)
	if err != nil {
		return 0, fmt.Errorf("failed to query stale services: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	count := 0
	for rows.Next() {
		var serviceType, serviceID string
		if err := rows.Scan(&serviceType, &serviceID); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to scan service row")
			continue
		}

		if err := r.DeleteService(ctx, serviceType, serviceID); err != nil {
			r.logger.Warn().
				Err(err).
				Str("service_type", serviceType).
				Str("service_id", serviceID).
				Msg("Failed to purge service")
			continue
		}

		count++
		r.logger.Debug().
			Str("service_type", serviceType).
			Str("service_id", serviceID).
			Msg("Purged service")
	}

	r.logger.Info().
		Int("purged_count", count).
		Dur("retention_period", retentionPeriod).
		Msg("Completed purge of inactive services")

	return count, nil
}
