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
	serviceTypeGateway  = "gateway"
	serviceTypeAgent   = "agent"
	serviceTypeChecker = "checker"
)

// GetGateway retrieves a gateway by ID.
func (r *ServiceRegistry) GetGateway(ctx context.Context, gatewayID string) (*RegisteredGateway, error) {
	return r.getGatewayCNPG(ctx, gatewayID)
}

// GetAgent retrieves an agent by ID.
func (r *ServiceRegistry) GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error) {
	return r.getAgentCNPG(ctx, agentID)
}

// GetChecker retrieves a checker by ID.
func (r *ServiceRegistry) GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error) {
	return r.getCheckerCNPG(ctx, checkerID)
}

// ListGateways retrieves all gateways matching filter.
func (r *ServiceRegistry) ListGateways(ctx context.Context, filter *ServiceFilter) ([]*RegisteredGateway, error) {
	if filter == nil {
		filter = &ServiceFilter{}
	}

	return r.listGatewaysCNPG(ctx, filter)
}

// ListAgentsByGateway retrieves all agents under a gateway.
func (r *ServiceRegistry) ListAgentsByGateway(ctx context.Context, gatewayID string) ([]*RegisteredAgent, error) {
	return r.listAgentsByGatewayCNPG(ctx, gatewayID)
}

// ListCheckersByAgent retrieves all checkers under an agent.
func (r *ServiceRegistry) ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error) {
	return r.listCheckersByAgentCNPG(ctx, agentID)
}

// UpdateServiceStatus updates the status of a service.
func (r *ServiceRegistry) UpdateServiceStatus(ctx context.Context, serviceType string, serviceID string, status ServiceStatus) error {
	switch serviceType {
	case serviceTypeGateway:
		gateway, err := r.GetGateway(ctx, serviceID)
		if err != nil {
			return err
		}
		gateway.Status = status

		if err := r.upsertCNPGGateway(ctx, gateway); err != nil {
			return err
		}

	case serviceTypeAgent:
		agent, err := r.GetAgent(ctx, serviceID)
		if err != nil {
			return err
		}
		agent.Status = status

		if err := r.upsertCNPGAgent(ctx, agent); err != nil {
			return err
		}

	case serviceTypeChecker:
		checker, err := r.GetChecker(ctx, serviceID)
		if err != nil {
			return err
		}
		checker.Status = status

		if err := r.upsertCNPGChecker(ctx, checker); err != nil {
			return err
		}

	default:
		return fmt.Errorf("%w: %s", ErrUnknownServiceType, serviceType)
	}

	r.logger.Info().
		Str("service_type", serviceType).
		Str("service_id", serviceID).
		Str("new_status", string(status)).
		Msg("Updated service status")

	return nil
}

// IsKnownGateway checks if a gateway is registered and active/pending.
// This replaces the logic in pkg/core/gateways.go
func (r *ServiceRegistry) IsKnownGateway(ctx context.Context, gatewayID string) (bool, error) {
	// Check cache first
	r.gatewayCacheMu.RLock()
	if time.Now().Before(r.cacheExpiry) {
		known, exists := r.gatewayCache[gatewayID]
		r.gatewayCacheMu.RUnlock()
		if exists {
			return known, nil
		}
	}
	r.gatewayCacheMu.RUnlock()

	known, err := r.isKnownGatewayCNPG(ctx, gatewayID)
	if err != nil {
		return false, err
	}

	// Update cache
	r.gatewayCacheMu.Lock()
	if time.Now().After(r.cacheExpiry) {
		// Refresh entire cache
		r.refreshGatewayCache(ctx)
	} else {
		r.gatewayCache[gatewayID] = known
	}
	r.gatewayCacheMu.Unlock()

	return known, nil
}

// refreshGatewayCache refreshes the entire gateway cache.
// Must be called with gatewayCacheMu locked.
func (r *ServiceRegistry) refreshGatewayCache(ctx context.Context) {
	r.refreshGatewayCacheCNPG(ctx)
}

// updateGatewayStatusByLastSeen is a helper function that updates gateway statuses based on last seen time.
func (r *ServiceRegistry) updateGatewayStatusByLastSeen(
	ctx context.Context,
	threshold time.Duration,
	filterStatus ServiceStatus,
	targetStatus ServiceStatus,
	successMsg, errorMsg string,
) (int, error) {
	cutoff := time.Now().UTC().Add(-threshold)
	count := 0

	gateways, err := r.ListGateways(ctx, &ServiceFilter{
		Statuses: []ServiceStatus{filterStatus},
	})
	if err != nil {
		return 0, err
	}

	for _, gateway := range gateways {
		if gateway.LastSeen != nil && gateway.LastSeen.Before(cutoff) {
			if err := r.UpdateServiceStatus(ctx, serviceTypeGateway, gateway.GatewayID, targetStatus); err != nil {
				r.logger.Warn().Err(err).Str("gateway_id", gateway.GatewayID).Msg(errorMsg)
			} else {
				count++
				r.logger.Info().
					Str("gateway_id", gateway.GatewayID).
					Time("last_seen", *gateway.LastSeen).
					Msg(successMsg)
			}
		}
	}

	return count, nil
}

// MarkInactive marks services as inactive if they haven't reported within threshold.
func (r *ServiceRegistry) MarkInactive(ctx context.Context, threshold time.Duration) (int, error) {
	return r.updateGatewayStatusByLastSeen(
		ctx,
		threshold,
		ServiceStatusActive,
		ServiceStatusInactive,
		"Marked gateway inactive",
		"Failed to mark gateway inactive",
	)
}

// ArchiveInactive archives services that have been inactive for longer than retention period.
func (r *ServiceRegistry) ArchiveInactive(ctx context.Context, retentionPeriod time.Duration) (int, error) {
	// For now, we'll just mark them as revoked rather than deleting
	// In the future, could move to separate archive table
	return r.updateGatewayStatusByLastSeen(
		ctx,
		retentionPeriod,
		ServiceStatusInactive,
		ServiceStatusRevoked,
		"Archived gateway",
		"Failed to archive gateway",
	)
}

func (r *ServiceRegistry) getGatewayCNPG(ctx context.Context, gatewayID string) (*RegisteredGateway, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
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
			agent_count,
			checker_count
		FROM gateways
		WHERE gateway_id = $1
		LIMIT 1`, gatewayID)
	if err != nil {
		return nil, fmt.Errorf("failed to query gateway: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	if !rows.Next() {
		return nil, fmt.Errorf("gateway not found: %w", db.ErrFailedToQuery)
	}

	var (
		gateway       RegisteredGateway
		statusStr    string
		sourceStr    string
		firstSeenPtr *time.Time
		lastSeenPtr  *time.Time
		metadataRaw  []byte
		agentCount   int
		checkerCount int
	)

	if err := rows.Scan(
		&gateway.GatewayID,
		&gateway.ComponentID,
		&statusStr,
		&sourceStr,
		&gateway.FirstRegistered,
		&firstSeenPtr,
		&lastSeenPtr,
		&metadataRaw,
		&gateway.SPIFFEIdentity,
		&gateway.CreatedBy,
		&agentCount,
		&checkerCount,
	); err != nil {
		return nil, fmt.Errorf("failed to scan gateway: %w", err)
	}

	gateway.Status = ServiceStatus(statusStr)
	gateway.RegistrationSource = RegistrationSource(sourceStr)
	gateway.FirstSeen = firstSeenPtr
	gateway.LastSeen = lastSeenPtr
	gateway.AgentCount = agentCount
	gateway.CheckerCount = checkerCount
	gateway.Metadata = decodeServiceMetadata(metadataRaw)

	return &gateway, rows.Err()
}

func (r *ServiceRegistry) getAgentCNPG(ctx context.Context, agentID string) (*RegisteredAgent, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
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
		&agent.GatewayID,
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
		&checker.GatewayID,
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

func (r *ServiceRegistry) listGatewaysCNPG(ctx context.Context, filter *ServiceFilter) ([]*RegisteredGateway, error) {
	builder := strings.Builder{}
	builder.WriteString(`
SELECT
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
	agent_count,
	checker_count
FROM gateways
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
		return nil, fmt.Errorf("failed to list gateways: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	var gateways []*RegisteredGateway

	for rows.Next() {
		var (
			gateway       RegisteredGateway
			statusStr    string
			sourceStr    string
			firstSeenPtr *time.Time
			lastSeenPtr  *time.Time
			metadataRaw  []byte
			agentCount   int
			checkerCount int
		)

		if err := rows.Scan(
			&gateway.GatewayID,
			&gateway.ComponentID,
			&statusStr,
			&sourceStr,
			&gateway.FirstRegistered,
			&firstSeenPtr,
			&lastSeenPtr,
			&metadataRaw,
			&gateway.SPIFFEIdentity,
			&gateway.CreatedBy,
			&agentCount,
			&checkerCount,
		); err != nil {
			r.logger.Error().Err(err).Msg("Error scanning gateway")
			continue
		}

		gateway.Status = ServiceStatus(statusStr)
		gateway.RegistrationSource = RegistrationSource(sourceStr)
		gateway.FirstSeen = firstSeenPtr
		gateway.LastSeen = lastSeenPtr
		gateway.AgentCount = agentCount
		gateway.CheckerCount = checkerCount
		gateway.Metadata = decodeServiceMetadata(metadataRaw)

		gateways = append(gateways, &gateway)
	}

	return gateways, rows.Err()
}

func (r *ServiceRegistry) listAgentsByGatewayCNPG(ctx context.Context, gatewayID string) ([]*RegisteredAgent, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT
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
		FROM agents
		WHERE gateway_id = $1
		ORDER BY first_registered DESC`, gatewayID)
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
			&agent.GatewayID,
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
			&checker.GatewayID,
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

func (r *ServiceRegistry) isKnownGatewayCNPG(ctx context.Context, gatewayID string) (bool, error) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT COUNT(*)
		FROM gateways
		WHERE gateway_id = $1
		  AND status IN ('pending', 'active')`, gatewayID)
	if err != nil {
		return false, fmt.Errorf("failed to check gateway: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	if !rows.Next() {
		return false, fmt.Errorf("failed to check gateway: %w", db.ErrFailedToQuery)
	}

	var count int
	if err := rows.Scan(&count); err != nil {
		return false, fmt.Errorf("failed to scan gateway count: %w", err)
	}

	return count > 0, rows.Err()
}

func (r *ServiceRegistry) refreshGatewayCacheCNPG(ctx context.Context) {
	rows, err := r.queryCNPGRows(ctx, `
		SELECT gateway_id
		FROM gateways
		WHERE status IN ('pending', 'active')`)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to refresh gateway cache (cnpg)")
		return
	}
	defer func() {
		_ = rows.Close()
	}()

	newCache := make(map[string]bool)
	for rows.Next() {
		var gatewayID string
		if err := rows.Scan(&gatewayID); err != nil {
			continue
		}
		newCache[gatewayID] = true
	}

	if err := rows.Err(); err != nil {
		r.logger.Warn().Err(err).Msg("Error while refreshing gateway cache (cnpg)")
		return
	}

	r.gatewayCache = newCache
	r.cacheExpiry = time.Now().Add(gatewayCacheTTL)

	r.logger.Debug().
		Int("cache_size", len(newCache)).
		Msg("Refreshed gateway cache (cnpg)")
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
