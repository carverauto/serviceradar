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
	upsertPollerStatusSQL = `
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
	is_healthy,
	agent_count,
	checker_count,
	updated_at
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14
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
	is_healthy = EXCLUDED.is_healthy,
	agent_count = EXCLUDED.agent_count,
	checker_count = EXCLUDED.checker_count,
	updated_at = EXCLUDED.updated_at`

	insertPollerHistorySQL = `
INSERT INTO poller_history (
	timestamp,
	poller_id,
	is_healthy
) VALUES ($1,$2,$3)`

	insertServiceStatusSQL = `
INSERT INTO service_status (
	timestamp,
	poller_id,
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
	poller_id,
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

func (db *DB) cnpgUpsertPollerStatus(ctx context.Context, status *models.PollerStatus) error {
	if !db.useCNPGWrites() || status == nil {
		return nil
	}

	args, err := buildCNPGPollerStatusArgs(status)
	if err != nil {
		return err
	}

	batch := &pgx.Batch{}
	batch.Queue(upsertPollerStatusSQL, args...)

	return db.sendCNPG(ctx, batch, "poller status")
}

func (db *DB) cnpgInsertPollerHistory(ctx context.Context, status *models.PollerStatus) error {
	if !db.useCNPGWrites() || status == nil {
		return nil
	}

	ts := sanitizeTimestamp(status.LastSeen)

	batch := &pgx.Batch{}
	batch.Queue(insertPollerHistorySQL, ts, strings.TrimSpace(status.PollerID), status.IsHealthy)

	return db.sendCNPG(ctx, batch, "poller history")
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
				Str("poller_id", safeServicePollerID(status)).
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
				Str("poller_id", safeServicePollerIDFromService(svc)).
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

func buildCNPGPollerStatusArgs(status *models.PollerStatus) ([]interface{}, error) {
	if status == nil {
		return nil, ErrPollerStatusNil
	}

	id := strings.TrimSpace(status.PollerID)
	if id == "" {
		return nil, ErrPollerIDMissing
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
		"system",
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

	if strings.TrimSpace(status.PollerID) == "" {
		return nil, ErrServiceStatusPollerIDMissing
	}

	ts := sanitizeTimestamp(status.Timestamp)
	details := normalizeRawJSON(status.Details)

	return []interface{}{
		ts,
		status.PollerID,
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

	if strings.TrimSpace(service.PollerID) == "" {
		return nil, ErrServicePollerIDMissing
	}

	config, err := marshalMapToJSON(service.Config)
	if err != nil {
		return nil, fmt.Errorf("service config: %w", err)
	}

	ts := sanitizeTimestamp(service.Timestamp)

	return []interface{}{
		ts,
		service.PollerID,
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

func safeServicePollerID(status *models.ServiceStatus) string {
	if status == nil {
		return ""
	}
	return status.PollerID
}

func safeServicePollerIDFromService(svc *models.Service) string {
	if svc == nil {
		return ""
	}
	return svc.PollerID
}

func (db *DB) cnpgGetPollerStatus(ctx context.Context, pollerID string) (*models.PollerStatus, error) {
	if strings.TrimSpace(pollerID) == "" {
		return nil, fmt.Errorf("%w: poller not found", ErrFailedToQuery)
	}

	row := db.pgPool.QueryRow(ctx, `
		SELECT poller_id,
		       COALESCE(first_seen, first_registered),
		       COALESCE(last_seen, first_registered),
		       is_healthy
		FROM pollers
		WHERE poller_id = $1
		LIMIT 1`, pollerID)

	var status models.PollerStatus
	if err := row.Scan(&status.PollerID, &status.FirstSeen, &status.LastSeen, &status.IsHealthy); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: poller not found", ErrFailedToQuery)
		}

		return nil, fmt.Errorf("%w poller status: %w", ErrFailedToQuery, err)
	}

	return &status, nil
}

func (db *DB) cnpgGetPollerServices(ctx context.Context, pollerID string) ([]models.ServiceStatus, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT service_name, service_type, available, timestamp, agent_id, details
		FROM service_status
		WHERE poller_id = $1
		ORDER BY service_type, service_name`, pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w poller services: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var services []models.ServiceStatus

	for rows.Next() {
		var svc models.ServiceStatus
		if err := rows.Scan(&svc.ServiceName, &svc.ServiceType, &svc.Available, &svc.Timestamp, &svc.AgentID, &svc.Details); err != nil {
			return nil, fmt.Errorf("%w service row: %w", ErrFailedToScan, err)
		}
		svc.PollerID = pollerID
		services = append(services, svc)
	}

	return services, rows.Err()
}

func (db *DB) cnpgGetPollerHistoryPoints(ctx context.Context, pollerID string, limit int) ([]models.PollerHistoryPoint, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM poller_history
		WHERE poller_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`, pollerID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w poller history points: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var points []models.PollerHistoryPoint
	for rows.Next() {
		var point models.PollerHistoryPoint
		if err := rows.Scan(&point.Timestamp, &point.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history point: %w", ErrFailedToScan, err)
		}
		points = append(points, point)
	}

	return points, rows.Err()
}

func (db *DB) cnpgGetPollerHistory(ctx context.Context, pollerID string, limit int) ([]models.PollerStatus, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM poller_history
		WHERE poller_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`, pollerID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w poller history: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var history []models.PollerStatus
	for rows.Next() {
		var status models.PollerStatus
		status.PollerID = pollerID
		if err := rows.Scan(&status.LastSeen, &status.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history row: %w", ErrFailedToScan, err)
		}
		history = append(history, status)
	}

	return history, rows.Err()
}

func (db *DB) cnpgListPollers(ctx context.Context) ([]string, error) {
	rows, err := db.pgPool.Query(ctx, `SELECT poller_id FROM pollers`)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var pollerIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("%w: failed to scan poller id: %w", ErrFailedToScan, err)
		}
		pollerIDs = append(pollerIDs, id)
	}

	return pollerIDs, rows.Err()
}

func (db *DB) cnpgListPollerStatuses(ctx context.Context, patterns []string) ([]models.PollerStatus, error) {
	query := `SELECT poller_id, is_healthy, last_seen FROM pollers`

	args := make([]interface{}, 0, len(patterns))
	if len(patterns) > 0 {
		conds := make([]string, len(patterns))
		for i, pattern := range patterns {
			args = append(args, pattern)
			conds[i] = fmt.Sprintf("poller_id LIKE $%d", len(args))
		}
		query += " WHERE " + strings.Join(conds, " OR ")
	}

	query += " ORDER BY last_seen DESC"

	rows, err := db.pgPool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var statuses []models.PollerStatus
	for rows.Next() {
		var status models.PollerStatus
		if err := rows.Scan(&status.PollerID, &status.IsHealthy, &status.LastSeen); err != nil {
			return nil, fmt.Errorf("%w: failed to scan poller status: %w", ErrFailedToScan, err)
		}
		statuses = append(statuses, status)
	}

	return statuses, rows.Err()
}

func (db *DB) cnpgListNeverReportedPollers(ctx context.Context, patterns []string) ([]string, error) {
	queryBuilder := strings.Builder{}
	queryBuilder.WriteString(`
WITH history AS (
	SELECT poller_id, MAX(timestamp) AS latest_timestamp
	FROM poller_history
	GROUP BY poller_id
)
SELECT DISTINCT p.poller_id
FROM pollers p
LEFT JOIN history h ON p.poller_id = h.poller_id
WHERE h.latest_timestamp IS NULL OR h.latest_timestamp = p.first_seen`)

	args := make([]interface{}, 0, len(patterns))
	if len(patterns) > 0 {
		conds := make([]string, len(patterns))
		for i, pattern := range patterns {
			args = append(args, pattern)
			conds[i] = fmt.Sprintf("p.poller_id LIKE $%d", len(args))
		}
		queryBuilder.WriteString(" AND (" + strings.Join(conds, " OR ") + ")")
	}

	queryBuilder.WriteString(" ORDER BY p.poller_id")

	rows, err := db.pgPool.Query(ctx, queryBuilder.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query never reported pollers: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var pollerIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("%w: failed to scan poller id: %w", ErrFailedToScan, err)
		}
		pollerIDs = append(pollerIDs, id)
	}

	return pollerIDs, rows.Err()
}

func (db *DB) cnpgListAgentsWithPollers(ctx context.Context) ([]AgentInfo, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT
			agent_id,
			poller_id,
			MAX(timestamp) AS last_seen,
			COALESCE(array_agg(DISTINCT service_type) FILTER (WHERE service_type <> ''), '{}') AS service_types
		FROM services
		WHERE agent_id <> ''
		GROUP BY agent_id, poller_id
		ORDER BY last_seen DESC`)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query agents: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var agents []AgentInfo
	for rows.Next() {
		var agent AgentInfo
		var serviceTypes []string
		if err := rows.Scan(&agent.AgentID, &agent.PollerID, &agent.LastSeen, &serviceTypes); err != nil {
			return nil, fmt.Errorf("%w: failed to scan agent info: %w", ErrFailedToScan, err)
		}
		agent.ServiceTypes = serviceTypes
		agents = append(agents, agent)
	}

	return agents, rows.Err()
}

func (db *DB) cnpgListAgentsByPoller(ctx context.Context, pollerID string) ([]AgentInfo, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT
			agent_id,
			poller_id,
			MAX(timestamp) AS last_seen,
			COALESCE(array_agg(DISTINCT service_type) FILTER (WHERE service_type <> ''), '{}') AS service_types
		FROM services
		WHERE agent_id <> '' AND poller_id = $1
		GROUP BY agent_id, poller_id
		ORDER BY last_seen DESC`, pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query agents for poller: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var agents []AgentInfo
	for rows.Next() {
		var agent AgentInfo
		var serviceTypes []string
		if err := rows.Scan(&agent.AgentID, &agent.PollerID, &agent.LastSeen, &serviceTypes); err != nil {
			return nil, fmt.Errorf("%w: failed to scan agent info: %w", ErrFailedToScan, err)
		}
		agent.ServiceTypes = serviceTypes
		agents = append(agents, agent)
	}

	return agents, rows.Err()
}

func (db *DB) cnpgGetServiceHistory(ctx context.Context, pollerID, serviceName string, limit int) ([]models.ServiceStatus, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, available, details
		FROM service_status
		WHERE poller_id = $1 AND service_name = $2
		ORDER BY timestamp DESC
		LIMIT $3`, pollerID, serviceName, limit)
	if err != nil {
		return nil, fmt.Errorf("%w service history: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var history []models.ServiceStatus
	for rows.Next() {
		var s models.ServiceStatus
		s.PollerID = pollerID
		s.ServiceName = serviceName
		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("%w service history row: %w", ErrFailedToScan, err)
		}
		history = append(history, s)
	}

	return history, rows.Err()
}
