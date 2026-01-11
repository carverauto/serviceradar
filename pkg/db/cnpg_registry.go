package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ServiceRegistrationEvent represents an audit record stored in CNPG.
type ServiceRegistrationEvent struct {
	EventID            string
	EventType          string
	ServiceID          string
	ServiceType        string
	ParentID           string
	RegistrationSource string
	Actor              string
	Timestamp          time.Time
	Metadata           map[string]string
}

const (
	upsertGatewayStatusSQL = `
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
	is_healthy,
	agent_count,
	checker_count,
	updated_at
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14
)
ON CONFLICT (gateway_id) DO UPDATE SET
	last_seen = EXCLUDED.last_seen,
	is_healthy = EXCLUDED.is_healthy,
	updated_at = EXCLUDED.updated_at`

	insertGatewayHistorySQL = `
INSERT INTO gateway_history (
	timestamp,
	gateway_id,
	is_healthy
) VALUES ($1,$2,$3)`

	insertServiceStatusSQL = `
INSERT INTO service_status (
	timestamp,
	gateway_id,
	agent_id,
	service_name,
	service_type,
	available,
	message,
	details,
	partition
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9
)`

	insertServicesSQL = `
INSERT INTO services (
	timestamp,
	gateway_id,
	agent_id,
	service_name,
	service_type,
	config,
	partition
) VALUES (
	$1,$2,$3,$4,$5,$6,$7
)`

	insertServiceRegistrationEventSQL = `
INSERT INTO service_registration_events (
	event_id,
	event_type,
	service_id,
	service_type,
	parent_id,
	registration_source,
	actor,
	timestamp,
	metadata
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9
)`
)

func (db *DB) cnpgUpsertGatewayStatus(ctx context.Context, status *models.GatewayStatus) error {
	if !db.useCNPGWrites() || status == nil {
		return nil
	}

	args, err := buildCNPGGatewayStatusArgs(status)
	if err != nil {
		return err
	}

	batch := &pgx.Batch{}
	batch.Queue(upsertGatewayStatusSQL, args...)

	return db.sendCNPG(ctx, batch, "gateway status")
}

func (db *DB) cnpgInsertGatewayHistory(ctx context.Context, status *models.GatewayStatus) error {
	if !db.useCNPGWrites() || status == nil {
		return nil
	}

	ts := sanitizeTimestamp(status.LastSeen)

	batch := &pgx.Batch{}
	batch.Queue(insertGatewayHistorySQL, ts, strings.TrimSpace(status.GatewayID), status.IsHealthy)

	return db.sendCNPG(ctx, batch, "gateway history")
}

func (db *DB) cnpgInsertServiceStatuses(ctx context.Context, statuses []*models.ServiceStatus) error {
	if len(statuses) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, status := range statuses {
		args, err := buildCNPGServiceStatusArgs(status)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("gateway_id", safeServiceGatewayID(status)).
				Msg("skipping CNPG service status")
			continue
		}
		batch.Queue(insertServiceStatusSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "service status")
}

func (db *DB) cnpgInsertServices(ctx context.Context, services []*models.Service) error {
	if len(services) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, svc := range services {
		args, err := buildCNPGServiceArgs(svc)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("gateway_id", safeServiceGatewayIDFromService(svc)).
				Msg("skipping CNPG service insert")
			continue
		}
		batch.Queue(insertServicesSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "services")
}

// InsertServiceRegistrationEvents appends registration audit events to CNPG.
func (db *DB) InsertServiceRegistrationEvents(ctx context.Context, events []*ServiceRegistrationEvent) error {
	if len(events) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, event := range events {
		args, err := buildCNPGServiceRegistrationEventArgs(event)
		if err != nil {
			return err
		}
		batch.Queue(insertServiceRegistrationEventSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "service registration event")
}

func buildCNPGGatewayStatusArgs(status *models.GatewayStatus) ([]interface{}, error) {
	if status == nil {
		return nil, ErrGatewayStatusNil
	}

	id := strings.TrimSpace(status.GatewayID)
	if id == "" {
		return nil, ErrGatewayIDMissing
	}

	firstSeen := sanitizeTimestamp(status.FirstSeen)
	lastSeen := sanitizeTimestamp(status.LastSeen)

	return []interface{}{
		id,
		"",         // component_id
		"implicit", // registration_source
		"active",   // status
		"",         // spiffe_identity
		firstSeen,  // first_registered
		firstSeen,  // first_seen
		lastSeen,   // last_seen
		json.RawMessage(`{}`),
		systemActor,
		status.IsHealthy,
		int32(0),
		int32(0),
		nowUTC(),
	}, nil
}

func buildCNPGServiceStatusArgs(status *models.ServiceStatus) ([]interface{}, error) {
	if status == nil {
		return nil, ErrServiceStatusNil
	}

	if strings.TrimSpace(status.GatewayID) == "" {
		return nil, ErrServiceStatusGatewayIDMissing
	}

	ts := sanitizeTimestamp(status.Timestamp)
	details := normalizeRawJSON(status.Details)

	return []interface{}{
		ts,
		status.GatewayID,
		status.AgentID,
		status.ServiceName,
		status.ServiceType,
		status.Available,
		strings.TrimSpace(status.Message),
		details,
		status.Partition,
	}, nil
}

func buildCNPGServiceArgs(service *models.Service) ([]interface{}, error) {
	if service == nil {
		return nil, ErrServiceNil
	}

	if strings.TrimSpace(service.GatewayID) == "" {
		return nil, ErrServiceGatewayIDMissing
	}

	config, err := marshalMapToJSON(service.Config)
	if err != nil {
		return nil, fmt.Errorf("service config: %w", err)
	}

	ts := sanitizeTimestamp(service.Timestamp)

	return []interface{}{
		ts,
		service.GatewayID,
		service.AgentID,
		service.ServiceName,
		service.ServiceType,
		config,
		service.Partition,
	}, nil
}

func buildCNPGServiceRegistrationEventArgs(event *ServiceRegistrationEvent) ([]interface{}, error) {
	if event == nil {
		return nil, ErrServiceRegistrationEventNil
	}

	timestamp := sanitizeTimestamp(event.Timestamp)

	metadata := event.Metadata
	if metadata == nil {
		metadata = map[string]string{}
	}

	rawMetadata, err := json.Marshal(metadata)
	if err != nil {
		return nil, fmt.Errorf("marshal service registration metadata: %w", err)
	}

	return []interface{}{
		strings.TrimSpace(event.EventID),
		strings.TrimSpace(event.EventType),
		strings.TrimSpace(event.ServiceID),
		strings.TrimSpace(event.ServiceType),
		strings.TrimSpace(event.ParentID),
		strings.TrimSpace(event.RegistrationSource),
		strings.TrimSpace(event.Actor),
		timestamp,
		json.RawMessage(rawMetadata),
	}, nil
}

func marshalMapToJSON(m map[string]string) (json.RawMessage, error) {
	if len(m) == 0 {
		return json.RawMessage(`{}`), nil
	}
	b, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(b), nil
}

func normalizeRawJSON(raw json.RawMessage) interface{} {
	if len(raw) == 0 {
		return nil
	}
	return raw
}

func safeServiceGatewayID(status *models.ServiceStatus) string {
	if status == nil {
		return ""
	}
	return status.GatewayID
}

func safeServiceGatewayIDFromService(svc *models.Service) string {
	if svc == nil {
		return ""
	}
	return svc.GatewayID
}

func (db *DB) cnpgGetGatewayStatus(ctx context.Context, gatewayID string) (*models.GatewayStatus, error) {
	if strings.TrimSpace(gatewayID) == "" {
		return nil, fmt.Errorf("%w: gateway not found", ErrFailedToQuery)
	}

	row := db.pgPool.QueryRow(ctx, `
		SELECT gateway_id,
		       COALESCE(first_seen, first_registered),
		       COALESCE(last_seen, first_registered),
		       is_healthy
		FROM gateways
		WHERE gateway_id = $1
		LIMIT 1`, gatewayID)

	var status models.GatewayStatus
	if err := row.Scan(&status.GatewayID, &status.FirstSeen, &status.LastSeen, &status.IsHealthy); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: gateway not found", ErrFailedToQuery)
		}

		return nil, fmt.Errorf("%w gateway status: %w", ErrFailedToQuery, err)
	}

	return &status, nil
}

func (db *DB) cnpgGetGatewayServices(ctx context.Context, gatewayID string) ([]models.ServiceStatus, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT service_name, service_type, available, timestamp, agent_id, details
		FROM service_status
		WHERE gateway_id = $1
		ORDER BY service_type, service_name`, gatewayID)
	if err != nil {
		return nil, fmt.Errorf("%w gateway services: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var services []models.ServiceStatus

	for rows.Next() {
		var svc models.ServiceStatus
		if err := rows.Scan(&svc.ServiceName, &svc.ServiceType, &svc.Available, &svc.Timestamp, &svc.AgentID, &svc.Details); err != nil {
			return nil, fmt.Errorf("%w service row: %w", ErrFailedToScan, err)
		}
		svc.GatewayID = gatewayID
		services = append(services, svc)
	}

	return services, rows.Err()
}

func (db *DB) cnpgGetGatewayHistoryPoints(ctx context.Context, gatewayID string, limit int) ([]models.GatewayHistoryPoint, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM gateway_history
		WHERE gateway_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`, gatewayID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w gateway history points: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var points []models.GatewayHistoryPoint
	for rows.Next() {
		var point models.GatewayHistoryPoint
		if err := rows.Scan(&point.Timestamp, &point.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history point: %w", ErrFailedToScan, err)
		}
		points = append(points, point)
	}

	return points, rows.Err()
}

func (db *DB) cnpgGetGatewayHistory(ctx context.Context, gatewayID string, limit int) ([]models.GatewayStatus, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM gateway_history
		WHERE gateway_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`, gatewayID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w gateway history: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var history []models.GatewayStatus
	for rows.Next() {
		var status models.GatewayStatus
		status.GatewayID = gatewayID
		if err := rows.Scan(&status.LastSeen, &status.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history row: %w", ErrFailedToScan, err)
		}
		history = append(history, status)
	}

	return history, rows.Err()
}

func (db *DB) cnpgListGateways(ctx context.Context) ([]string, error) {
	rows, err := db.pgPool.Query(ctx, `SELECT gateway_id FROM gateways`)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query gateways: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var gatewayIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("%w: failed to scan gateway id: %w", ErrFailedToScan, err)
		}
		gatewayIDs = append(gatewayIDs, id)
	}

	return gatewayIDs, rows.Err()
}

func (db *DB) cnpgListGatewayStatuses(ctx context.Context, patterns []string) ([]models.GatewayStatus, error) {
	query := `SELECT gateway_id, is_healthy, last_seen FROM gateways`

	args := make([]interface{}, 0, len(patterns))
	if len(patterns) > 0 {
		conds := make([]string, len(patterns))
		for i, pattern := range patterns {
			args = append(args, pattern)
			conds[i] = fmt.Sprintf("gateway_id LIKE $%d", len(args))
		}
		query += " WHERE " + strings.Join(conds, " OR ")
	}

	query += " ORDER BY last_seen DESC"

	rows, err := db.pgPool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query gateways: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var statuses []models.GatewayStatus
	for rows.Next() {
		var status models.GatewayStatus
		if err := rows.Scan(&status.GatewayID, &status.IsHealthy, &status.LastSeen); err != nil {
			return nil, fmt.Errorf("%w: failed to scan gateway status: %w", ErrFailedToScan, err)
		}
		statuses = append(statuses, status)
	}

	return statuses, rows.Err()
}

func (db *DB) cnpgListNeverReportedGateways(ctx context.Context, patterns []string) ([]string, error) {
	queryBuilder := strings.Builder{}
	queryBuilder.WriteString(`
WITH history AS (
	SELECT gateway_id, MAX(timestamp) AS latest_timestamp
	FROM gateway_history
	GROUP BY gateway_id
)
SELECT DISTINCT p.gateway_id
FROM gateways p
LEFT JOIN history h ON p.gateway_id = h.gateway_id
WHERE h.latest_timestamp IS NULL OR h.latest_timestamp = p.first_seen`)

	args := make([]interface{}, 0, len(patterns))
	if len(patterns) > 0 {
		conds := make([]string, len(patterns))
		for i, pattern := range patterns {
			args = append(args, pattern)
			conds[i] = fmt.Sprintf("p.gateway_id LIKE $%d", len(args))
		}
		queryBuilder.WriteString(" AND (" + strings.Join(conds, " OR ") + ")")
	}

	queryBuilder.WriteString(" ORDER BY p.gateway_id")

	rows, err := db.pgPool.Query(ctx, queryBuilder.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query never reported gateways: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var gatewayIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("%w: failed to scan gateway id: %w", ErrFailedToScan, err)
		}
		gatewayIDs = append(gatewayIDs, id)
	}

	return gatewayIDs, rows.Err()
}

func (db *DB) cnpgListAgentsWithGateways(ctx context.Context) ([]AgentInfo, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT
			agent_id,
			gateway_id,
			MAX(timestamp) AS last_seen,
			COALESCE(array_agg(DISTINCT service_type) FILTER (WHERE service_type <> ''), '{}') AS service_types
		FROM services
		WHERE agent_id <> ''
		GROUP BY agent_id, gateway_id
		ORDER BY last_seen DESC`)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query agents: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var agents []AgentInfo
	for rows.Next() {
		var agent AgentInfo
		var serviceTypes []string
		if err := rows.Scan(&agent.AgentID, &agent.GatewayID, &agent.LastSeen, &serviceTypes); err != nil {
			return nil, fmt.Errorf("%w: failed to scan agent info: %w", ErrFailedToScan, err)
		}
		agent.ServiceTypes = serviceTypes
		agents = append(agents, agent)
	}

	return agents, rows.Err()
}

func (db *DB) cnpgListAgentsByGateway(ctx context.Context, gatewayID string) ([]AgentInfo, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT
			agent_id,
			gateway_id,
			MAX(timestamp) AS last_seen,
			COALESCE(array_agg(DISTINCT service_type) FILTER (WHERE service_type <> ''), '{}') AS service_types
		FROM services
		WHERE agent_id <> '' AND gateway_id = $1
		GROUP BY agent_id, gateway_id
		ORDER BY last_seen DESC`, gatewayID)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query agents for gateway: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var agents []AgentInfo
	for rows.Next() {
		var agent AgentInfo
		var serviceTypes []string
		if err := rows.Scan(&agent.AgentID, &agent.GatewayID, &agent.LastSeen, &serviceTypes); err != nil {
			return nil, fmt.Errorf("%w: failed to scan agent info: %w", ErrFailedToScan, err)
		}
		agent.ServiceTypes = serviceTypes
		agents = append(agents, agent)
	}

	return agents, rows.Err()
}

func (db *DB) cnpgGetServiceHistory(ctx context.Context, gatewayID, serviceName string, limit int) ([]models.ServiceStatus, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, available, details
		FROM service_status
		WHERE gateway_id = $1 AND service_name = $2
		ORDER BY timestamp DESC
		LIMIT $3`, gatewayID, serviceName, limit)
	if err != nil {
		return nil, fmt.Errorf("%w service history: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var history []models.ServiceStatus
	for rows.Next() {
		var s models.ServiceStatus
		s.GatewayID = gatewayID
		s.ServiceName = serviceName
		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("%w service history row: %w", ErrFailedToScan, err)
		}
		history = append(history, s)
	}

	return history, rows.Err()
}
