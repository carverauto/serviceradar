package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

var (
	// ErrPollerAlreadyRegistered is returned when a poller is already registered.
	ErrPollerAlreadyRegistered = errors.New("poller already registered")
	// ErrParentPollerNotFound is returned when a parent poller is not found.
	ErrParentPollerNotFound = errors.New("parent poller not found")
	// ErrAgentAlreadyRegistered is returned when an agent is already registered.
	ErrAgentAlreadyRegistered = errors.New("agent already registered")
	// ErrParentAgentNotFound is returned when a parent agent is not found.
	ErrParentAgentNotFound = errors.New("parent agent not found")
	// ErrCheckerAlreadyRegistered is returned when a checker is already registered.
	ErrCheckerAlreadyRegistered = errors.New("checker already registered")
	// ErrUnknownServiceType is returned when an unknown service type is encountered.
	ErrUnknownServiceType = errors.New("unknown service type")
	// ErrCannotDeleteActiveService is returned when trying to delete an active service.
	ErrCannotDeleteActiveService = errors.New("cannot delete service: mark inactive/revoked/deleted first")
)

const (
	// pollerCacheTTL defines how long to cache IsKnownPoller results
	pollerCacheTTL = 5 * time.Minute
)

const (
	cnpgUpsertPollerSQL = `
INSERT INTO pollers (
	poller_id,
	component_id,
	registration_source,
	status,
	spiffe_identity,
	first_registered,
	first_seen,
	last_seen,
	metadata,
	created_by,
	agent_count,
	checker_count
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
)
ON CONFLICT (poller_id) DO UPDATE SET
	component_id = EXCLUDED.component_id,
	registration_source = EXCLUDED.registration_source,
	status = EXCLUDED.status,
	spiffe_identity = EXCLUDED.spiffe_identity,
	first_registered = EXCLUDED.first_registered,
	first_seen = EXCLUDED.first_seen,
	last_seen = EXCLUDED.last_seen,
	metadata = EXCLUDED.metadata,
	created_by = EXCLUDED.created_by,
	agent_count = EXCLUDED.agent_count,
	checker_count = EXCLUDED.checker_count,
	updated_at = now()`

	cnpgUpsertAgentSQL = `
INSERT INTO agents (
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
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
)
ON CONFLICT (agent_id) DO UPDATE SET
	poller_id = EXCLUDED.poller_id,
	component_id = EXCLUDED.component_id,
	status = EXCLUDED.status,
	registration_source = EXCLUDED.registration_source,
	first_registered = EXCLUDED.first_registered,
	first_seen = EXCLUDED.first_seen,
	last_seen = EXCLUDED.last_seen,
	metadata = EXCLUDED.metadata,
	spiffe_identity = EXCLUDED.spiffe_identity,
	created_by = EXCLUDED.created_by,
	checker_count = EXCLUDED.checker_count,
	updated_at = now()`

	cnpgUpsertCheckerSQL = `
INSERT INTO checkers (
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
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13
)
ON CONFLICT (checker_id) DO UPDATE SET
	agent_id = EXCLUDED.agent_id,
	poller_id = EXCLUDED.poller_id,
	checker_kind = EXCLUDED.checker_kind,
	component_id = EXCLUDED.component_id,
	status = EXCLUDED.status,
	registration_source = EXCLUDED.registration_source,
	first_registered = EXCLUDED.first_registered,
	first_seen = EXCLUDED.first_seen,
	last_seen = EXCLUDED.last_seen,
	metadata = EXCLUDED.metadata,
	spiffe_identity = EXCLUDED.spiffe_identity,
	created_by = EXCLUDED.created_by,
	updated_at = now()`

	cnpgDeletePollerSQL  = `DELETE FROM pollers WHERE poller_id = $1`
	cnpgDeleteAgentSQL   = `DELETE FROM agents WHERE agent_id = $1`
	cnpgDeleteCheckerSQL = `DELETE FROM checkers WHERE checker_id = $1`
)

// ServiceRegistry implements the ServiceManager interface.
// It manages the lifecycle and registration of all services (pollers, agents, checkers).
type ServiceRegistry struct {
	db         *db.DB
	logger     zerolog.Logger
	cnpgClient cnpgRegistryClient

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
		cnpgClient:  database,
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
		return fmt.Errorf("%w: %s with status %s", ErrPollerAlreadyRegistered, reg.PollerID, existing.Status)
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

	firstSeen := now
	lastSeen := now
	pollerRecord := &RegisteredPoller{
		PollerID:           reg.PollerID,
		ComponentID:        reg.ComponentID,
		Status:             ServiceStatusPending,
		RegistrationSource: reg.RegistrationSource,
		FirstRegistered:    now,
		FirstSeen:          &firstSeen,
		LastSeen:           &lastSeen,
		Metadata:           reg.Metadata,
		SPIFFEIdentity:     reg.SPIFFEIdentity,
		CreatedBy:          reg.CreatedBy,
	}

	if err := r.upsertCNPGPoller(ctx, pollerRecord); err != nil {
		return err
	}

	// Emit registration event
	eventMetadata := map[string]string{
		"component_id": reg.ComponentID,
	}
	if reg.SPIFFEIdentity != "" {
		eventMetadata["spiffe_id"] = reg.SPIFFEIdentity
	}
	if err := r.emitRegistrationEvent(ctx, "registered", serviceTypePoller, reg.PollerID, "", reg.RegistrationSource, reg.CreatedBy, eventMetadata); err != nil {
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
			return fmt.Errorf("%w: %s", ErrParentPollerNotFound, reg.PollerID)
		}
	}

	// Check if already exists
	existing, err := r.GetAgent(ctx, reg.AgentID)
	if err == nil && existing != nil {
		r.logger.Warn().
			Str("agent_id", reg.AgentID).
			Str("status", string(existing.Status)).
			Msg("Agent already registered")
		return fmt.Errorf("%w: %s with status %s", ErrAgentAlreadyRegistered, reg.AgentID, existing.Status)
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

	firstSeen := now
	lastSeen := now
	agentRecord := &RegisteredAgent{
		AgentID:            reg.AgentID,
		PollerID:           reg.PollerID,
		ComponentID:        reg.ComponentID,
		Status:             ServiceStatusPending,
		RegistrationSource: reg.RegistrationSource,
		FirstRegistered:    now,
		FirstSeen:          &firstSeen,
		LastSeen:           &lastSeen,
		Metadata:           reg.Metadata,
		SPIFFEIdentity:     reg.SPIFFEIdentity,
		CreatedBy:          reg.CreatedBy,
	}

	if err := r.upsertCNPGAgent(ctx, agentRecord); err != nil {
		return err
	}

	// Emit registration event
	eventMetadata := map[string]string{
		"component_id": reg.ComponentID,
		"poller_id":    reg.PollerID,
	}
	if reg.SPIFFEIdentity != "" {
		eventMetadata["spiffe_id"] = reg.SPIFFEIdentity
	}
	if err := r.emitRegistrationEvent(ctx, "registered", serviceTypeAgent, reg.AgentID, reg.PollerID, reg.RegistrationSource, reg.CreatedBy, eventMetadata); err != nil {
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
			return fmt.Errorf("%w: %s", ErrParentAgentNotFound, reg.AgentID)
		}
	}

	// Check if already exists
	existing, err := r.GetChecker(ctx, reg.CheckerID)
	if err == nil && existing != nil {
		r.logger.Warn().
			Str("checker_id", reg.CheckerID).
			Str("status", string(existing.Status)).
			Msg("Checker already registered")
		return fmt.Errorf("%w: %s with status %s", ErrCheckerAlreadyRegistered, reg.CheckerID, existing.Status)
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

	firstSeen := now
	lastSeen := now
	checkerRecord := &RegisteredChecker{
		CheckerID:          reg.CheckerID,
		AgentID:            reg.AgentID,
		PollerID:           reg.PollerID,
		CheckerKind:        reg.CheckerKind,
		ComponentID:        reg.ComponentID,
		Status:             ServiceStatusPending,
		RegistrationSource: reg.RegistrationSource,
		FirstRegistered:    now,
		FirstSeen:          &firstSeen,
		LastSeen:           &lastSeen,
		Metadata:           reg.Metadata,
		SPIFFEIdentity:     reg.SPIFFEIdentity,
		CreatedBy:          reg.CreatedBy,
	}

	if err := r.upsertCNPGChecker(ctx, checkerRecord); err != nil {
		return err
	}

	// Emit registration event
	eventMetadata := map[string]string{
		"component_id": reg.ComponentID,
		"agent_id":     reg.AgentID,
		"poller_id":    reg.PollerID,
		"checker_kind": reg.CheckerKind,
	}
	if reg.SPIFFEIdentity != "" {
		eventMetadata["spiffe_id"] = reg.SPIFFEIdentity
	}
	if err := r.emitRegistrationEvent(ctx, "registered", serviceTypeChecker, reg.CheckerID, reg.AgentID, reg.RegistrationSource, reg.CreatedBy, eventMetadata); err != nil {
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
	case serviceTypePoller:
		return r.recordPollerHeartbeat(ctx, heartbeat.PollerID, now, heartbeat.SourceIP)
	case serviceTypeAgent:
		return r.recordAgentHeartbeat(ctx, heartbeat.AgentID, heartbeat.PollerID, now, heartbeat.SourceIP)
	case serviceTypeChecker:
		return r.recordCheckerHeartbeat(ctx, heartbeat.CheckerID, heartbeat.AgentID, heartbeat.PollerID, now)
	default:
		return fmt.Errorf("%w: %s", ErrUnknownServiceType, heartbeat.ServiceType)
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

	updatedPoller := &RegisteredPoller{
		PollerID:           poller.PollerID,
		ComponentID:        poller.ComponentID,
		Status:             newStatus,
		RegistrationSource: poller.RegistrationSource,
		FirstRegistered:    poller.FirstRegistered,
		FirstSeen:          firstSeen,
		LastSeen:           &timestamp,
		Metadata:           poller.Metadata,
		SPIFFEIdentity:     poller.SPIFFEIdentity,
		CreatedBy:          poller.CreatedBy,
		AgentCount:         poller.AgentCount,
		CheckerCount:       poller.CheckerCount,
	}

	if err := r.upsertCNPGPoller(ctx, updatedPoller); err != nil {
		return err
	}

	// Emit activation event if transitioned to active
	if poller.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		eventMetadata := map[string]string{
			"component_id": poller.ComponentID,
		}
		if sourceIP != "" {
			eventMetadata["source_ip"] = sourceIP
		}
		if err := r.emitRegistrationEvent(ctx, "activated", serviceTypePoller, pollerID, "", poller.RegistrationSource, "system", eventMetadata); err != nil {
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

	updatedAgent := &RegisteredAgent{
		AgentID:            agent.AgentID,
		PollerID:           agent.PollerID,
		ComponentID:        agent.ComponentID,
		Status:             newStatus,
		RegistrationSource: agent.RegistrationSource,
		FirstRegistered:    agent.FirstRegistered,
		FirstSeen:          firstSeen,
		LastSeen:           &timestamp,
		Metadata:           agent.Metadata,
		SPIFFEIdentity:     agent.SPIFFEIdentity,
		CreatedBy:          agent.CreatedBy,
		CheckerCount:       agent.CheckerCount,
	}

	if err := r.upsertCNPGAgent(ctx, updatedAgent); err != nil {
		return err
	}

	// Emit activation event if transitioned to active
	if agent.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		eventMetadata := map[string]string{
			"component_id": agent.ComponentID,
			"poller_id":    pollerID,
		}
		if sourceIP != "" {
			eventMetadata["source_ip"] = sourceIP
		}
		if err := r.emitRegistrationEvent(ctx, "activated", serviceTypeAgent, agentID, pollerID, agent.RegistrationSource, "system", eventMetadata); err != nil {
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
			Str("poller_id", pollerID).
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

	updatedChecker := &RegisteredChecker{
		CheckerID:          checker.CheckerID,
		AgentID:            checker.AgentID,
		PollerID:           checker.PollerID,
		CheckerKind:        checker.CheckerKind,
		ComponentID:        checker.ComponentID,
		Status:             newStatus,
		RegistrationSource: checker.RegistrationSource,
		FirstRegistered:    checker.FirstRegistered,
		FirstSeen:          firstSeen,
		LastSeen:           &timestamp,
		Metadata:           checker.Metadata,
		SPIFFEIdentity:     checker.SPIFFEIdentity,
		CreatedBy:          checker.CreatedBy,
	}

	if err := r.upsertCNPGChecker(ctx, updatedChecker); err != nil {
		return err
	}

	// Emit activation event if transitioned to active
	if checker.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		eventMetadata := map[string]string{
			"component_id": checker.ComponentID,
			"agent_id":     agentID,
			"poller_id":    pollerID,
			"checker_kind": checker.CheckerKind,
		}
		if err := r.emitRegistrationEvent(ctx, "activated", serviceTypeChecker, checkerID, agentID, checker.RegistrationSource, "system", eventMetadata); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("checker_id", checkerID).
			Str("agent_id", agentID).
			Str("poller_id", pollerID).
			Msg("Checker activated on first heartbeat")
	}

	return nil
}

// emitRegistrationEvent emits an audit event to the service_registration_events stream.
func (r *ServiceRegistry) emitRegistrationEvent(ctx context.Context, eventType, serviceType, serviceID, parentID string, source RegistrationSource, actor string, metadata map[string]string) error {
	if metadata == nil {
		metadata = map[string]string{}
	}
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
	case serviceTypePoller:
		query = `SELECT status, registration_source FROM pollers WHERE poller_id = ? LIMIT 1`
	case serviceTypeAgent:
		query = `SELECT status, registration_source FROM agents WHERE agent_id = ? LIMIT 1`
	case serviceTypeChecker:
		query = `SELECT status, registration_source FROM checkers WHERE checker_id = ? LIMIT 1`
	default:
		return fmt.Errorf("%w: %s", ErrUnknownServiceType, serviceType)
	}

	row := r.db.Conn.QueryRow(ctx, query, serviceID)
	if err := row.Scan(&status, &source); err != nil {
		return fmt.Errorf("service not found: %w", err)
	}

	if status == string(ServiceStatusActive) || status == string(ServiceStatusPending) {
		return fmt.Errorf("%w: %s with status %s", ErrCannotDeleteActiveService, serviceID, status)
	}

	// Emit deletion event BEFORE deleting
	metadata := map[string]string{
		"service_id": serviceID,
	}
	if err := r.emitRegistrationEvent(ctx, "deleted", serviceType, serviceID, "", RegistrationSource(source), "system", metadata); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit deletion event")
	}

	// Hard delete from stream
	// Note: For versioned_kv streams in Timeplus/ClickHouse, we use DELETE FROM
	var deleteQuery string
	switch serviceType {
	case serviceTypePoller:
		deleteQuery = `DELETE FROM pollers WHERE poller_id = ?`
	case serviceTypeAgent:
		deleteQuery = `DELETE FROM agents WHERE agent_id = ?`
	case serviceTypeChecker:
		deleteQuery = `DELETE FROM checkers WHERE checker_id = ?`
	}

	if err := r.db.Conn.Exec(ctx, deleteQuery, serviceID); err != nil {
		return fmt.Errorf("failed to delete service: %w", err)
	}

	if err := r.deleteServiceCNPG(ctx, serviceType, serviceID); err != nil {
		return err
	}

	// Invalidate cache if it's a poller
	if serviceType == serviceTypePoller {
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

func (r *ServiceRegistry) getCNPGClient() (cnpgRegistryClient, bool) {
	if r == nil {
		return nil, false
	}

	if r.cnpgClient != nil {
		return r.cnpgClient, true
	}

	if r.db == nil {
		return nil, false
	}

	client, ok := interface{}(r.db).(cnpgRegistryClient)
	if !ok {
		return nil, false
	}

	r.cnpgClient = client
	return client, true
}

func (r *ServiceRegistry) useCNPGReads() bool {
	client, ok := r.getCNPGClient()
	if !ok {
		return false
	}

	return client.UseCNPGReads()
}

func (r *ServiceRegistry) queryCNPGRows(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
	client, ok := r.getCNPGClient()
	if !ok {
		return nil, fmt.Errorf("cnpg querying is not supported by service registry db")
	}

	return client.QueryCNPGRows(ctx, query, args...)
}

func (r *ServiceRegistry) shouldWriteCNPG() bool {
	return r != nil && r.db != nil && r.db.UseCNPGWrites()
}

func (r *ServiceRegistry) execCNPGWrite(ctx context.Context, query string, args ...interface{}) error {
	if !r.shouldWriteCNPG() {
		return nil
	}

	if err := r.db.ExecCNPG(ctx, query, args...); err != nil {
		return err
	}

	return nil
}

func marshalServiceMetadata(metadata map[string]string) ([]byte, error) {
	if metadata == nil {
		metadata = map[string]string{}
	}
	return json.Marshal(metadata)
}

func (r *ServiceRegistry) upsertCNPGPoller(ctx context.Context, poller *RegisteredPoller) error {
	if poller == nil || !r.shouldWriteCNPG() {
		return nil
	}

	metadataJSON, err := marshalServiceMetadata(poller.Metadata)
	if err != nil {
		return fmt.Errorf("marshal poller metadata: %w", err)
	}

	if err := r.execCNPGWrite(ctx, cnpgUpsertPollerSQL,
		poller.PollerID,
		poller.ComponentID,
		string(poller.RegistrationSource),
		string(poller.Status),
		poller.SPIFFEIdentity,
		poller.FirstRegistered,
		poller.FirstSeen,
		poller.LastSeen,
		metadataJSON,
		poller.CreatedBy,
		poller.AgentCount,
		poller.CheckerCount,
	); err != nil {
		return fmt.Errorf("cnpg upsert poller: %w", err)
	}

	return nil
}

func (r *ServiceRegistry) upsertCNPGAgent(ctx context.Context, agent *RegisteredAgent) error {
	if agent == nil || !r.shouldWriteCNPG() {
		return nil
	}

	metadataJSON, err := marshalServiceMetadata(agent.Metadata)
	if err != nil {
		return fmt.Errorf("marshal agent metadata: %w", err)
	}

	if err := r.execCNPGWrite(ctx, cnpgUpsertAgentSQL,
		agent.AgentID,
		agent.PollerID,
		agent.ComponentID,
		string(agent.Status),
		string(agent.RegistrationSource),
		agent.FirstRegistered,
		agent.FirstSeen,
		agent.LastSeen,
		metadataJSON,
		agent.SPIFFEIdentity,
		agent.CreatedBy,
		agent.CheckerCount,
	); err != nil {
		return fmt.Errorf("cnpg upsert agent: %w", err)
	}

	return nil
}

func (r *ServiceRegistry) upsertCNPGChecker(ctx context.Context, checker *RegisteredChecker) error {
	if checker == nil || !r.shouldWriteCNPG() {
		return nil
	}

	metadataJSON, err := marshalServiceMetadata(checker.Metadata)
	if err != nil {
		return fmt.Errorf("marshal checker metadata: %w", err)
	}

	if err := r.execCNPGWrite(ctx, cnpgUpsertCheckerSQL,
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
		metadataJSON,
		checker.SPIFFEIdentity,
		checker.CreatedBy,
	); err != nil {
		return fmt.Errorf("cnpg upsert checker: %w", err)
	}

	return nil
}

func (r *ServiceRegistry) deleteServiceCNPG(ctx context.Context, serviceType, serviceID string) error {
	if !r.shouldWriteCNPG() {
		return nil
	}

	var query string

	switch serviceType {
	case serviceTypePoller:
		query = cnpgDeletePollerSQL
	case serviceTypeAgent:
		query = cnpgDeleteAgentSQL
	case serviceTypeChecker:
		query = cnpgDeleteCheckerSQL
	default:
		return fmt.Errorf("%w: %s", ErrUnknownServiceType, serviceType)
	}

	if err := r.execCNPGWrite(ctx, query, serviceID); err != nil {
		return fmt.Errorf("cnpg delete %s: %w", serviceType, err)
	}

	return nil
}
