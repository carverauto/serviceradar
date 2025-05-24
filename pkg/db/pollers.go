package db

import (
	"context"
	"errors"
	"fmt"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"
	"log"
	"strings"
	"time"
)

// GetPollerStatus retrieves a poller's current status.
func (db *DB) GetPollerStatus(ctx context.Context, pollerID string) (*models.PollerStatus, error) {
	var status models.PollerStatus

	rows, err := db.Conn.Query(ctx, `
		SELECT poller_id, first_seen, last_seen, is_healthy
		FROM table(pollers)
		WHERE poller_id = $1
		LIMIT 1`,
		pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w poller status: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	if !rows.Next() {
		return nil, fmt.Errorf("%w: poller not found", ErrFailedToQuery)
	}

	err = rows.Scan(
		&status.PollerID,
		&status.FirstSeen,
		&status.LastSeen,
		&status.IsHealthy,
	)
	if err != nil {
		return nil, fmt.Errorf("%w poller status: %w", ErrFailedToScan, err)
	}

	return &status, nil
}

// GetPollerServices retrieves services for a poller.
func (db *DB) GetPollerServices(ctx context.Context, pollerID string) ([]models.ServiceStatus, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT service_name, service_type, available, details, timestamp, agent_id
		FROM table(service_status)
		WHERE poller_id = $1
		ORDER BY service_type, service_name`,
		pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w poller services: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var services []models.ServiceStatus

	for rows.Next() {
		var s models.ServiceStatus

		if err := rows.Scan(&s.ServiceName, &s.ServiceType, &s.Available, &s.Details, &s.Timestamp, &s.AgentID); err != nil {
			return nil, fmt.Errorf("%w service row: %w", ErrFailedToScan, err)
		}

		services = append(services, s)
	}

	return services, nil
}

// GetPollerHistoryPoints retrieves history points for a poller.
func (db *DB) GetPollerHistoryPoints(ctx context.Context, pollerID string, limit int) ([]models.PollerHistoryPoint, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM table(poller_history)
		WHERE poller_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`,
		pollerID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w poller history points: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var points []models.PollerHistoryPoint

	for rows.Next() {
		var point models.PollerHistoryPoint

		if err := rows.Scan(&point.Timestamp, &point.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history point: %w", ErrFailedToScan, err)
		}

		points = append(points, point)
	}

	return points, nil
}

// GetPollerHistory retrieves the history for a poller.
func (db *DB) GetPollerHistory(ctx context.Context, pollerID string) ([]models.PollerStatus, error) {
	const maxHistoryPoints = 1000

	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM table(poller_history)
		WHERE poller_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`,
		pollerID, maxHistoryPoints)
	if err != nil {
		return nil, fmt.Errorf("%w poller history: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var history []models.PollerStatus

	for rows.Next() {
		var status models.PollerStatus

		status.PollerID = pollerID
		if err := rows.Scan(&status.LastSeen, &status.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history row: %w", ErrFailedToScan, err)
		}

		history = append(history, status)
	}

	return history, nil
}

// IsPollerOffline checks if a poller is offline based on the threshold.
func (db *DB) IsPollerOffline(ctx context.Context, pollerID string, threshold time.Duration) (bool, error) {
	cutoff := time.Now().Add(-threshold)

	rows, err := db.Conn.Query(ctx, `
		SELECT COUNT(*)
		FROM table(pollers)
		WHERE poller_id = $1
		AND last_seen < $2`,
		pollerID, cutoff)
	if err != nil {
		return false, fmt.Errorf("%w poller status: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var count int

	if !rows.Next() {
		return false, fmt.Errorf("%w: count result not found", ErrFailedToQuery)
	}

	if err := rows.Scan(&count); err != nil {
		return false, fmt.Errorf("%w count: %w", ErrFailedToScan, err)
	}

	return count > 0, nil
}

// ListPollers retrieves all poller IDs from the pollers stream.
func (db *DB) ListPollers(ctx context.Context) ([]string, error) {
	rows, err := db.Conn.Query(ctx, "SELECT poller_id FROM table(pollers)")
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var pollerIDs []string

	for rows.Next() {
		var pollerID string

		if err := rows.Scan(&pollerID); err != nil {
			log.Printf("Error scanning poller ID: %v", err)

			continue
		}

		pollerIDs = append(pollerIDs, pollerID)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: error iterating rows: %w", ErrFailedToQuery, err)
	}

	return pollerIDs, nil
}

// DeletePoller deletes a poller by ID.
func (db *DB) DeletePoller(ctx context.Context, pollerID string) error {
	batch, err := db.Conn.PrepareBatch(ctx, "DELETE FROM table(pollers) WHERE poller_id = $1")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	if err := batch.Append(pollerID); err != nil {
		return fmt.Errorf("failed to append poller ID: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w: failed to delete poller: %w", ErrFailedToInsert, err)
	}

	return nil
}

// ListPollerStatuses retrieves poller statuses, optionally filtered by patterns.
func (db *DB) ListPollerStatuses(ctx context.Context, patterns []string) ([]models.PollerStatus, error) {
	query := `SELECT poller_id, is_healthy, last_seen FROM table(pollers)`

	var args []interface{}

	if len(patterns) > 0 {
		conditions := make([]string, 0, len(patterns))

		for _, pattern := range patterns {
			conditions = append(conditions, "poller_id LIKE $1")
			args = append(args, pattern)
		}

		query += " WHERE " + strings.Join(conditions, " OR ")
	}

	query += " ORDER BY last_seen DESC"

	rows, err := db.Conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var statuses []models.PollerStatus

	for rows.Next() {
		var status models.PollerStatus

		if err := rows.Scan(&status.PollerID, &status.IsHealthy, &status.LastSeen); err != nil {
			log.Printf("Error scanning poller status: %v", err)

			continue
		}

		statuses = append(statuses, status)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: error iterating rows: %w", ErrFailedToQuery, err)
	}

	return statuses, nil
}

// ListNeverReportedPollers retrieves poller IDs that have never reported (first_seen = last_seen).
func (db *DB) ListNeverReportedPollers(ctx context.Context, patterns []string) ([]string, error) {
	query := `
        WITH history AS (
            SELECT poller_id, MAX(timestamp) AS latest_timestamp
            FROM table(poller_history)
            GROUP BY poller_id
        )
        SELECT DISTINCT p.poller_id
        FROM table(pollers) AS p
        LEFT JOIN history ON p.poller_id = history.poller_id
        WHERE history.latest_timestamp IS NULL OR history.latest_timestamp = p.first_seen`

	var args []interface{}

	if len(patterns) > 0 {
		conditions := make([]string, 0, len(patterns))

		for i, pattern := range patterns {
			conditions = append(conditions, fmt.Sprintf("p.poller_id LIKE $%d", i+1))
			args = append(args, pattern)
		}

		query += " AND (" + strings.Join(conditions, " OR ") + ")"
	}

	query += " ORDER BY p.poller_id"

	rows, err := db.Conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query never reported pollers: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var pollerIDs []string

	for rows.Next() {
		var pollerID string

		if err := rows.Scan(&pollerID); err != nil {
			log.Printf("Error scanning poller ID: %v", err)
			continue
		}

		pollerIDs = append(pollerIDs, pollerID)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: error iterating rows: %w", ErrFailedToQuery, err)
	}

	log.Printf("Found %d never reported pollers: %v", len(pollerIDs), pollerIDs)

	return pollerIDs, nil
}

// UpdatePollerStatus updates a poller's status and logs it in the history.
func (db *DB) UpdatePollerStatus(ctx context.Context, status *models.PollerStatus) error {
	if err := validatePollerStatus(status); err != nil {
		return err
	}

	// Preserve original FirstSeen if poller exists
	if err := db.preserveFirstSeen(ctx, status); err != nil {
		return fmt.Errorf("failed to check poller existence: %w", err)
	}

	// Update pollers table
	if err := db.insertPollerStatus(ctx, status); err != nil {
		log.Printf("Failed to update poller status for %s: %v", status.PollerID, err)
		return fmt.Errorf("failed to update poller status: %w", err)
	}

	// Check if status has changed before logging to poller_history
	existing, err := db.GetPollerStatus(ctx, status.PollerID)
	if err != nil && !errors.Is(err, ErrFailedToQuery) {
		return fmt.Errorf("failed to check existing poller status: %w", err)
	}

	if existing == nil || existing.IsHealthy != status.IsHealthy || existing.LastSeen != status.LastSeen {
		if err := db.insertPollerHistory(ctx, status); err != nil {
			log.Printf("Failed to add poller history for %s: %v", status.PollerID, err)
			return fmt.Errorf("failed to add poller history: %w", err)
		}
	}

	log.Printf("Successfully updated poller status for %s", status.PollerID)

	return nil
}

var (
	errInvalidPollerID = errors.New("invalid poller ID")
)

// validatePollerStatus ensures the poller status is valid and sets default timestamps.
func validatePollerStatus(status *models.PollerStatus) error {
	if status.PollerID == "" {
		return errInvalidPollerID
	}

	now := time.Now()
	if !isValidTimestamp(status.FirstSeen) {
		status.FirstSeen = now
	}

	if !isValidTimestamp(status.LastSeen) {
		status.LastSeen = now
	}

	return nil
}

// preserveFirstSeen retrieves the existing poller and preserves its FirstSeen timestamp.
func (db *DB) preserveFirstSeen(ctx context.Context, status *models.PollerStatus) error {
	existing, err := db.GetPollerStatus(ctx, status.PollerID)
	if err != nil && !errors.Is(err, ErrFailedToQuery) {
		return err
	}

	if existing != nil {
		status.FirstSeen = existing.FirstSeen
	}

	return nil
}

// insertPollerStatus inserts or updates the poller status in the pollers table.
func (db *DB) insertPollerStatus(ctx context.Context, status *models.PollerStatus) error {
	return db.executeBatch(ctx, "INSERT INTO pollers (* except _tp_time)", func(batch driver.Batch) error {
		return batch.Append(
			status.PollerID,
			status.FirstSeen,
			status.LastSeen,
			status.IsHealthy,
		)
	})
}

// insertPollerHistory logs the poller status in the poller_history table.
func (db *DB) insertPollerHistory(ctx context.Context, status *models.PollerStatus) error {
	return db.executeBatch(ctx, "INSERT INTO poller_history (* except _tp_time)", func(batch driver.Batch) error {
		return batch.Append(
			status.PollerID,
			status.LastSeen,
			status.IsHealthy,
		)
	})
}
