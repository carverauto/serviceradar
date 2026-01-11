package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// AgentInfo summarizes agent metadata for gateway listings.
type AgentInfo struct {
	AgentID      string
	GatewayID     string
	LastSeen     time.Time
	ServiceTypes []string
}

// GetGatewayStatus retrieves a gateway's current status from CNPG.
func (db *DB) GetGatewayStatus(ctx context.Context, gatewayID string) (*models.GatewayStatus, error) {
	return db.cnpgGetGatewayStatus(ctx, gatewayID)
}

// GetGatewayServices retrieves services for a gateway.
func (db *DB) GetGatewayServices(ctx context.Context, gatewayID string) ([]models.ServiceStatus, error) {
	return db.cnpgGetGatewayServices(ctx, gatewayID)
}

// GetGatewayHistoryPoints retrieves recent history points for a gateway.
func (db *DB) GetGatewayHistoryPoints(ctx context.Context, gatewayID string, limit int) ([]models.GatewayHistoryPoint, error) {
	if limit <= 0 {
		limit = 100
	}
	return db.cnpgGetGatewayHistoryPoints(ctx, gatewayID, limit)
}

// GetGatewayHistory retrieves the full history for a gateway (bounded to 1000 entries).
func (db *DB) GetGatewayHistory(ctx context.Context, gatewayID string) ([]models.GatewayStatus, error) {
	return db.cnpgGetGatewayHistory(ctx, gatewayID, 1000)
}

// IsGatewayOffline checks if a gateway is offline based on the threshold.
func (db *DB) IsGatewayOffline(ctx context.Context, gatewayID string, threshold time.Duration) (bool, error) {
	if !db.cnpgConfigured() {
		return false, ErrCNPGUnavailable
	}

	cutoff := time.Now().Add(-threshold).UTC()

	row := db.pgPool.QueryRow(ctx, `
        SELECT COUNT(*)
        FROM gateways
        WHERE gateway_id = $1
          AND last_seen < $2`, gatewayID, cutoff)

	var count int64
	if err := row.Scan(&count); err != nil {
		return false, fmt.Errorf("failed to check gateway status: %w", err)
	}

	return count > 0, nil
}

// ListGateways retrieves all gateway IDs.
func (db *DB) ListGateways(ctx context.Context) ([]string, error) {
	return db.cnpgListGateways(ctx)
}

// DeleteGateway removes a gateway record.
func (db *DB) DeleteGateway(ctx context.Context, gatewayID string) error {
	if strings.TrimSpace(gatewayID) == "" {
		return ErrGatewayIDMissing
	}

	return db.ExecCNPG(ctx, "DELETE FROM gateways WHERE gateway_id = $1", gatewayID)
}

// ListGatewayStatuses retrieves gateway statuses, optionally filtered by patterns.
func (db *DB) ListGatewayStatuses(ctx context.Context, patterns []string) ([]models.GatewayStatus, error) {
	return db.cnpgListGatewayStatuses(ctx, patterns)
}

// ListNeverReportedGateways lists gateways that never reported history events.
func (db *DB) ListNeverReportedGateways(ctx context.Context, patterns []string) ([]string, error) {
	return db.cnpgListNeverReportedGateways(ctx, patterns)
}

// UpdateGatewayStatus upserts the gateway status and records history.
func (db *DB) UpdateGatewayStatus(ctx context.Context, status *models.GatewayStatus) error {
	if status == nil {
		return ErrGatewayStatusNil
	}

	if err := db.cnpgUpsertGatewayStatus(ctx, status); err != nil {
		return err
	}

	return db.cnpgInsertGatewayHistory(ctx, status)
}

// ListAgentsWithGateways returns agent information grouped by gateway.
func (db *DB) ListAgentsWithGateways(ctx context.Context) ([]AgentInfo, error) {
	return db.cnpgListAgentsWithGateways(ctx)
}

// ListAgentsByGateway lists all agents for a specific gateway.
func (db *DB) ListAgentsByGateway(ctx context.Context, gatewayID string) ([]AgentInfo, error) {
	return db.cnpgListAgentsByGateway(ctx, gatewayID)
}
