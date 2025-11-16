package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// AgentInfo summarizes agent metadata for poller listings.
type AgentInfo struct {
	AgentID      string
	PollerID     string
	LastSeen     time.Time
	ServiceTypes []string
}

// GetPollerStatus retrieves a poller's current status from CNPG.
func (db *DB) GetPollerStatus(ctx context.Context, pollerID string) (*models.PollerStatus, error) {
	return db.cnpgGetPollerStatus(ctx, pollerID)
}

// GetPollerServices retrieves services for a poller.
func (db *DB) GetPollerServices(ctx context.Context, pollerID string) ([]models.ServiceStatus, error) {
	return db.cnpgGetPollerServices(ctx, pollerID)
}

// GetPollerHistoryPoints retrieves recent history points for a poller.
func (db *DB) GetPollerHistoryPoints(ctx context.Context, pollerID string, limit int) ([]models.PollerHistoryPoint, error) {
	if limit <= 0 {
		limit = 100
	}
	return db.cnpgGetPollerHistoryPoints(ctx, pollerID, limit)
}

// GetPollerHistory retrieves the full history for a poller (bounded to 1000 entries).
func (db *DB) GetPollerHistory(ctx context.Context, pollerID string) ([]models.PollerStatus, error) {
	return db.cnpgGetPollerHistory(ctx, pollerID, 1000)
}

// IsPollerOffline checks if a poller is offline based on the threshold.
func (db *DB) IsPollerOffline(ctx context.Context, pollerID string, threshold time.Duration) (bool, error) {
	if !db.cnpgConfigured() {
		return false, ErrCNPGUnavailable
	}

	cutoff := time.Now().Add(-threshold).UTC()

	row := db.pgPool.QueryRow(ctx, `
        SELECT COUNT(*)
        FROM pollers
        WHERE poller_id = $1
          AND last_seen < $2`, pollerID, cutoff)

	var count int64
	if err := row.Scan(&count); err != nil {
		return false, fmt.Errorf("failed to check poller status: %w", err)
	}

	return count > 0, nil
}

// ListPollers retrieves all poller IDs.
func (db *DB) ListPollers(ctx context.Context) ([]string, error) {
	return db.cnpgListPollers(ctx)
}

// DeletePoller removes a poller record.
func (db *DB) DeletePoller(ctx context.Context, pollerID string) error {
	if strings.TrimSpace(pollerID) == "" {
		return ErrPollerIDMissing
	}

	return db.ExecCNPG(ctx, "DELETE FROM pollers WHERE poller_id = $1", pollerID)
}

// ListPollerStatuses retrieves poller statuses, optionally filtered by patterns.
func (db *DB) ListPollerStatuses(ctx context.Context, patterns []string) ([]models.PollerStatus, error) {
	return db.cnpgListPollerStatuses(ctx, patterns)
}

// ListNeverReportedPollers lists pollers that never reported history events.
func (db *DB) ListNeverReportedPollers(ctx context.Context, patterns []string) ([]string, error) {
	return db.cnpgListNeverReportedPollers(ctx, patterns)
}

// UpdatePollerStatus upserts the poller status and records history.
func (db *DB) UpdatePollerStatus(ctx context.Context, status *models.PollerStatus) error {
	if status == nil {
		return ErrPollerStatusNil
	}

	if err := db.cnpgUpsertPollerStatus(ctx, status); err != nil {
		return err
	}

	return db.cnpgInsertPollerHistory(ctx, status)
}

// ListAgentsWithPollers returns agent information grouped by poller.
func (db *DB) ListAgentsWithPollers(ctx context.Context) ([]AgentInfo, error) {
	return db.cnpgListAgentsWithPollers(ctx)
}

// ListAgentsByPoller lists all agents for a specific poller.
func (db *DB) ListAgentsByPoller(ctx context.Context, pollerID string) ([]AgentInfo, error) {
	return db.cnpgListAgentsByPoller(ctx, pollerID)
}
