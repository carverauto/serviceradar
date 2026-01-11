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
	// ErrGatewayAlreadyRegistered is returned when a gateway is already registered.
	ErrGatewayAlreadyRegistered = errors.New("gateway already registered")
	// ErrParentGatewayNotFound is returned when a parent gateway is not found.
	ErrParentGatewayNotFound = errors.New("parent gateway not found")
	// ErrAgentAlreadyRegistered is returned when an agent is already registered.
	ErrAgentAlreadyRegistered = errors.New("agent already registered")
	// ErrParentAgentNotFound is returned when a parent agent is not found.
	ErrParentAgentNotFound = errors.New("parent agent not found")
	// ErrCheckerAlreadyRegistered is returned when a checker is already registered.
	ErrCheckerAlreadyRegistered = errors.New("checker already registered")
	// ErrUnknownServiceType is returned when an unknown service type is encountered.
	ErrUnknownServiceType = errors.New("unknown service type")
	// ErrCannotDeleteActiveService is returned when trying to delete an active service.
	ErrCannotDeleteActiveService      = errors.New("cannot delete service: mark inactive/revoked/deleted first")
	errServiceRegistryCNPGUnsupported = errors.New("cnpg querying is not supported by service registry db")
	errRegistrationEventWriterMissing = errors.New("registration event writer is not configured")
)

const (
	// gatewayCacheTTL defines how long to cache IsKnownGateway results
	gatewayCacheTTL = 5 * time.Minute
)

const (
	cnpgUpsertGatewaySQL = `
INSERT INTO gateways (
	gateway_id,
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
ON CONFLICT (gateway_id) DO UPDATE SET
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
	gateway_id,
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
	gateway_id = EXCLUDED.gateway_id,
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
	gateway_id,
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
	gateway_id = EXCLUDED.gateway_id,
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

	cnpgDeleteGatewaySQL  = `DELETE FROM gateways WHERE gateway_id = $1`
	cnpgDeleteAgentSQL   = `DELETE FROM agents WHERE agent_id = $1`
	cnpgDeleteCheckerSQL = `DELETE FROM checkers WHERE checker_id = $1`
)

// ServiceRegistry implements the ServiceManager interface.
// It manages the lifecycle and registration of all services (gateways, agents, checkers).
type ServiceRegistry struct {
	db          *db.DB
	logger      zerolog.Logger
	cnpgClient  cnpgRegistryClient
	eventWriter registrationEventWriter

	// Cache for IsKnownGateway() - invalidated on registration changes
	gatewayCacheMu sync.RWMutex
	gatewayCache   map[string]bool
	cacheExpiry   time.Time
}

type registrationEventWriter interface {
	InsertServiceRegistrationEvents(ctx context.Context, events []*db.ServiceRegistrationEvent) error
}

// NewServiceRegistry creates a new ServiceRegistry instance.
func NewServiceRegistry(database *db.DB, log logger.Logger) *ServiceRegistry {
	return &ServiceRegistry{
		db:          database,
		logger:      log.WithComponent("service-registry"),
		cnpgClient:  database,
		eventWriter: database,
		gatewayCache: make(map[string]bool),
	}
}

// RegisterGateway explicitly registers a new gateway.
func (r *ServiceRegistry) RegisterGateway(ctx context.Context, reg *GatewayRegistration) error {
	now := time.Now().UTC()

	// Check if already exists
	existing, err := r.GetGateway(ctx, reg.GatewayID)
	if err == nil && existing != nil {
		r.logger.Warn().
			Str("gateway_id", reg.GatewayID).
			Str("status", string(existing.Status)).
			Msg("Gateway already registered")
		return fmt.Errorf("%w: %s with status %s", ErrGatewayAlreadyRegistered, reg.GatewayID, existing.Status)
	}

	firstSeen := now
	lastSeen := now
	gatewayRecord := &RegisteredGateway{
		GatewayID:           reg.GatewayID,
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

	if err := r.upsertCNPGGateway(ctx, gatewayRecord); err != nil {
		return err
	}

	// Emit registration event
	eventMetadata := map[string]string{
		"component_id": reg.ComponentID,
	}
	if reg.SPIFFEIdentity != "" {
		eventMetadata["spiffe_id"] = reg.SPIFFEIdentity
	}
	if err := r.emitRegistrationEvent(ctx, "registered", serviceTypeGateway, reg.GatewayID, "", reg.RegistrationSource, reg.CreatedBy, eventMetadata); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit registration event")
	}

	// Invalidate cache
	r.invalidateGatewayCache()

	r.logger.Info().
		Str("gateway_id", reg.GatewayID).
		Str("component_id", reg.ComponentID).
		Str("source", string(reg.RegistrationSource)).
		Msg("Registered gateway")

	return nil
}

// RegisterAgent explicitly registers a new agent under a gateway.
func (r *ServiceRegistry) RegisterAgent(ctx context.Context, reg *AgentRegistration) error {
	now := time.Now().UTC()

	// Skip parent validation for implicit (auto-registration) to avoid timing issues
	// with versioned_kv materialization - we know the gateway just heartbeated
	if reg.RegistrationSource != RegistrationSourceImplicit {
		// Verify parent gateway exists for explicit registrations
		gateway, err := r.GetGateway(ctx, reg.GatewayID)
		if err != nil || gateway == nil {
			return fmt.Errorf("%w: %s", ErrParentGatewayNotFound, reg.GatewayID)
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

	firstSeen := now
	lastSeen := now
	agentRecord := &RegisteredAgent{
		AgentID:            reg.AgentID,
		GatewayID:           reg.GatewayID,
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
		"gateway_id":    reg.GatewayID,
	}
	if reg.SPIFFEIdentity != "" {
		eventMetadata["spiffe_id"] = reg.SPIFFEIdentity
	}
	if err := r.emitRegistrationEvent(ctx, "registered", serviceTypeAgent, reg.AgentID, reg.GatewayID, reg.RegistrationSource, reg.CreatedBy, eventMetadata); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit registration event")
	}

	r.logger.Info().
		Str("agent_id", reg.AgentID).
		Str("gateway_id", reg.GatewayID).
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

	firstSeen := now
	lastSeen := now
	checkerRecord := &RegisteredChecker{
		CheckerID:          reg.CheckerID,
		AgentID:            reg.AgentID,
		GatewayID:           reg.GatewayID,
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
		"gateway_id":    reg.GatewayID,
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
		Str("gateway_id", reg.GatewayID).
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
	case serviceTypeGateway:
		return r.recordGatewayHeartbeat(ctx, heartbeat.GatewayID, now, heartbeat.SourceIP)
	case serviceTypeAgent:
		return r.recordAgentHeartbeat(ctx, heartbeat.AgentID, heartbeat.GatewayID, now, heartbeat.SourceIP)
	case serviceTypeChecker:
		return r.recordCheckerHeartbeat(ctx, heartbeat.CheckerID, heartbeat.AgentID, heartbeat.GatewayID, now)
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

// recordGatewayHeartbeat updates gateway last_seen and activates if pending.
func (r *ServiceRegistry) recordGatewayHeartbeat(ctx context.Context, gatewayID string, timestamp time.Time, sourceIP string) error {
	// For ReplacingMergeTree, we insert a new row with updated values
	// The engine will keep the latest based on updated_at

	// First, get current state
	gateway, err := r.GetGateway(ctx, gatewayID)
	if err != nil {
		// Gateway not registered yet - register implicitly
		if err := r.RegisterGateway(ctx, &GatewayRegistration{
			GatewayID:           gatewayID,
			ComponentID:        gatewayID,
			RegistrationSource: RegistrationSourceImplicit,
			CreatedBy:          "system",
		}); err != nil {
			return fmt.Errorf("failed to auto-register gateway: %w", err)
		}
		gateway, _ = r.GetGateway(ctx, gatewayID)
	}

	// Determine new status
	newStatus := gateway.Status
	if gateway.Status == ServiceStatusPending {
		newStatus = ServiceStatusActive
	}

	// Set first_seen if this is the first report
	firstSeen := gateway.FirstSeen
	if firstSeen == nil {
		firstSeen = &timestamp
	}

	updatedGateway := &RegisteredGateway{
		GatewayID:           gateway.GatewayID,
		ComponentID:        gateway.ComponentID,
		Status:             newStatus,
		RegistrationSource: gateway.RegistrationSource,
		FirstRegistered:    gateway.FirstRegistered,
		FirstSeen:          firstSeen,
		LastSeen:           &timestamp,
		Metadata:           gateway.Metadata,
		SPIFFEIdentity:     gateway.SPIFFEIdentity,
		CreatedBy:          gateway.CreatedBy,
		AgentCount:         gateway.AgentCount,
		CheckerCount:       gateway.CheckerCount,
	}

	if err := r.upsertCNPGGateway(ctx, updatedGateway); err != nil {
		return err
	}

	// Emit activation event if transitioned to active
	if gateway.Status == ServiceStatusPending && newStatus == ServiceStatusActive {
		eventMetadata := map[string]string{
			"component_id": gateway.ComponentID,
		}
		if sourceIP != "" {
			eventMetadata["source_ip"] = sourceIP
		}
		if err := r.emitRegistrationEvent(ctx, "activated", serviceTypeGateway, gatewayID, "", gateway.RegistrationSource, "system", eventMetadata); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("gateway_id", gatewayID).
			Msg("Gateway activated on first heartbeat")
	}

	return nil
}

// recordAgentHeartbeat updates agent last_seen and activates if pending.
func (r *ServiceRegistry) recordAgentHeartbeat(ctx context.Context, agentID, gatewayID string, timestamp time.Time, sourceIP string) error {
	// Get current state
	agent, err := r.GetAgent(ctx, agentID)
	if err != nil {
		// Agent not registered yet - register implicitly
		if err := r.RegisterAgent(ctx, &AgentRegistration{
			AgentID:            agentID,
			GatewayID:           gatewayID,
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

	updatedAgent := &RegisteredAgent{
		AgentID:            agent.AgentID,
		GatewayID:           agent.GatewayID,
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
			"gateway_id":    gatewayID,
		}
		if sourceIP != "" {
			eventMetadata["source_ip"] = sourceIP
		}
		if err := r.emitRegistrationEvent(ctx, "activated", serviceTypeAgent, agentID, gatewayID, agent.RegistrationSource, "system", eventMetadata); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("agent_id", agentID).
			Str("gateway_id", gatewayID).
			Msg("Agent activated on first heartbeat")
	}

	return nil
}

// recordCheckerHeartbeat updates checker last_seen and activates if pending.
func (r *ServiceRegistry) recordCheckerHeartbeat(ctx context.Context, checkerID, agentID, gatewayID string, timestamp time.Time) error {
	// Get current state
	checker, err := r.GetChecker(ctx, checkerID)
	if err != nil {
		// Checker not registered - this shouldn't happen, but handle gracefully
		r.logger.Warn().
			Str("checker_id", checkerID).
			Str("agent_id", agentID).
			Str("gateway_id", gatewayID).
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

	updatedChecker := &RegisteredChecker{
		CheckerID:          checker.CheckerID,
		AgentID:            checker.AgentID,
		GatewayID:           checker.GatewayID,
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
			"gateway_id":    gatewayID,
			"checker_kind": checker.CheckerKind,
		}
		if err := r.emitRegistrationEvent(ctx, "activated", serviceTypeChecker, checkerID, agentID, checker.RegistrationSource, "system", eventMetadata); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to emit activation event")
		}
		r.logger.Info().
			Str("checker_id", checkerID).
			Str("agent_id", agentID).
			Str("gateway_id", gatewayID).
			Msg("Checker activated on first heartbeat")
	}

	return nil
}

// emitRegistrationEvent emits an audit event to the service_registration_events stream.
func (r *ServiceRegistry) emitRegistrationEvent(ctx context.Context, eventType, serviceType, serviceID, parentID string, source RegistrationSource, actor string, metadata map[string]string) error {
	if metadata == nil {
		metadata = map[string]string{}
	}
	writer, ok := r.getRegistrationEventWriter()
	if !ok {
		return errRegistrationEventWriterMissing
	}

	event := &db.ServiceRegistrationEvent{
		EventID:            uuid.New().String(),
		EventType:          eventType,
		ServiceID:          serviceID,
		ServiceType:        serviceType,
		ParentID:           parentID,
		RegistrationSource: string(source),
		Actor:              actor,
		Timestamp:          time.Now().UTC(),
		Metadata:           metadata,
	}

	return writer.InsertServiceRegistrationEvents(ctx, []*db.ServiceRegistrationEvent{event})
}

// invalidateGatewayCache clears the gateway cache.
func (r *ServiceRegistry) invalidateGatewayCache() {
	r.gatewayCacheMu.Lock()
	defer r.gatewayCacheMu.Unlock()

	r.gatewayCache = make(map[string]bool)
	r.cacheExpiry = time.Time{} // Zero time = expired
}

// DeleteService permanently deletes a service from the registry.
// This should only be called for services that are no longer needed (status: revoked, inactive, or deleted).
// Returns error if service is still active or pending.
func (r *ServiceRegistry) DeleteService(ctx context.Context, serviceType, serviceID string) error {
	// Verify service is not active or pending
	var (
		status ServiceStatus
		source RegistrationSource
		err    error
	)

	switch serviceType {
	case serviceTypeGateway:
		var gateway *RegisteredGateway
		gateway, err = r.GetGateway(ctx, serviceID)
		if err == nil && gateway != nil {
			status = gateway.Status
			source = gateway.RegistrationSource
		}
	case serviceTypeAgent:
		var agent *RegisteredAgent
		agent, err = r.GetAgent(ctx, serviceID)
		if err == nil && agent != nil {
			status = agent.Status
			source = agent.RegistrationSource
		}
	case serviceTypeChecker:
		var checker *RegisteredChecker
		checker, err = r.GetChecker(ctx, serviceID)
		if err == nil && checker != nil {
			status = checker.Status
			source = checker.RegistrationSource
		}
	default:
		return fmt.Errorf("%w: %s", ErrUnknownServiceType, serviceType)
	}

	if err != nil {
		return fmt.Errorf("service not found: %w", err)
	}

	if status == ServiceStatusActive || status == ServiceStatusPending {
		return fmt.Errorf("%w: %s with status %s", ErrCannotDeleteActiveService, serviceID, status)
	}

	// Emit deletion event BEFORE deleting
	metadata := map[string]string{
		"service_id": serviceID,
	}
	if err := r.emitRegistrationEvent(ctx, "deleted", serviceType, serviceID, "", source, "system", metadata); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to emit deletion event")
	}

	if err := r.deleteServiceCNPG(ctx, serviceType, serviceID); err != nil {
		return err
	}

	// Invalidate cache if it's a gateway
	if serviceType == serviceTypeGateway {
		r.invalidateGatewayCache()
	}

	r.logger.Info().
		Str("service_type", serviceType).
		Str("service_id", serviceID).
		Str("status", string(status)).
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
	rows, err := r.queryCNPGRows(ctx, `
		SELECT service_type, service_id
		FROM (
			SELECT 'gateway' AS service_type, gateway_id AS service_id, last_seen, status
			FROM gateways
			WHERE status IN ('inactive', 'revoked', 'deleted')
			  AND last_seen < $1

			UNION ALL

			SELECT 'gateway', gateway_id, first_registered AS last_seen, status
			FROM gateways
			WHERE status = 'pending'
			  AND first_seen IS NULL
			  AND first_registered < $2

			UNION ALL

			SELECT 'agent', agent_id, last_seen, status
			FROM agents
			WHERE status IN ('inactive', 'revoked', 'deleted')
			  AND last_seen < $3

			UNION ALL

			SELECT 'agent', agent_id, first_registered AS last_seen, status
			FROM agents
			WHERE status = 'pending'
			  AND first_seen IS NULL
			  AND first_registered < $4

			UNION ALL

			SELECT 'checker', checker_id, last_seen, status
			FROM checkers
			WHERE status IN ('inactive', 'revoked', 'deleted')
			  AND last_seen < $5

			UNION ALL

			SELECT 'checker', checker_id, first_registered AS last_seen, status
			FROM checkers
			WHERE status = 'pending'
			  AND first_seen IS NULL
			  AND first_registered < $6
		) AS stale_services`, cutoff, cutoff, cutoff, cutoff, cutoff, cutoff)
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

func (r *ServiceRegistry) getRegistrationEventWriter() (registrationEventWriter, bool) {
	if r == nil {
		return nil, false
	}

	if r.eventWriter != nil {
		return r.eventWriter, true
	}

	if r.db == nil {
		return nil, false
	}

	r.eventWriter = r.db
	return r.eventWriter, true
}

func (r *ServiceRegistry) queryCNPGRows(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
	client, ok := r.getCNPGClient()
	if !ok {
		return nil, errServiceRegistryCNPGUnsupported
	}

	return client.QueryRegistryRows(ctx, query, args...)
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

func (r *ServiceRegistry) upsertCNPGGateway(ctx context.Context, gateway *RegisteredGateway) error {
	if gateway == nil || !r.shouldWriteCNPG() {
		return nil
	}

	metadataJSON, err := marshalServiceMetadata(gateway.Metadata)
	if err != nil {
		return fmt.Errorf("marshal gateway metadata: %w", err)
	}

	if err := r.execCNPGWrite(ctx, cnpgUpsertGatewaySQL,
		gateway.GatewayID,
		gateway.ComponentID,
		string(gateway.RegistrationSource),
		string(gateway.Status),
		gateway.SPIFFEIdentity,
		gateway.FirstRegistered,
		gateway.FirstSeen,
		gateway.LastSeen,
		metadataJSON,
		gateway.CreatedBy,
		gateway.AgentCount,
		gateway.CheckerCount,
	); err != nil {
		return fmt.Errorf("cnpg upsert gateway: %w", err)
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
		agent.GatewayID,
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
		checker.GatewayID,
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
	case serviceTypeGateway:
		query = cnpgDeleteGatewaySQL
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
