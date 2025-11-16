package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultEdgeOnboardingPackageLimit = 100
	edgePackageProjection             = "package_id,label,component_id,component_type,parent_type,parent_id,poller_id," +
		"site,status,downstream_entry_id,downstream_spiffe_id,selectors,checker_kind,checker_config_json," +
		"join_token_ciphertext,join_token_expires_at,bundle_ciphertext,download_token_hash," +
		"download_token_expires_at,created_by,created_at,updated_at,delivered_at,activated_at," +
		"activated_from_ip,last_seen_spiffe_id,revoked_at,deleted_at,deleted_by,deleted_reason," +
		"metadata_json,kv_revision,notes"
)

func selectEdgePackageProjection() string {
	return edgePackageProjection
}

// UpsertEdgeOnboardingPackage inserts or replaces a package row.
func (db *DB) UpsertEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil {
		return fmt.Errorf("%w: edge onboarding package is nil", ErrEdgePackageInvalid)
	}

	return db.cnpgUpsertEdgeOnboardingPackage(ctx, pkg)
}

// GetEdgeOnboardingPackage fetches a single package by ID.
func (db *DB) GetEdgeOnboardingPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	parsed, err := uuid.Parse(strings.TrimSpace(packageID))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid package_id %q: %w", ErrEdgePackageInvalid, packageID, err)
	}

	row := db.pgPool.QueryRow(ctx, fmt.Sprintf(`
        SELECT %s
        FROM edge_onboarding_packages
        WHERE package_id = $1
        ORDER BY updated_at DESC
        LIMIT 1`, selectEdgePackageProjection()), parsed)

	pkg, scanErr := scanEdgeOnboardingPackage(row)
	if scanErr != nil {
		return nil, scanErr
	}

	return pkg, nil
}

// ListEdgeOnboardingPackages returns packages filtered by optional criteria.
func (db *DB) ListEdgeOnboardingPackages(ctx context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	queryBuilder := strings.Builder{}
	args := make([]interface{}, 0, 8)
	conditions := make([]string, 0, 6)
	argIdx := 1

	if filter != nil {
		if v := strings.TrimSpace(filter.PollerID); v != "" {
			conditions = append(conditions, fmt.Sprintf("poller_id = $%d", argIdx))
			args = append(args, v)
			argIdx++
		}
		if v := strings.TrimSpace(filter.ComponentID); v != "" {
			conditions = append(conditions, fmt.Sprintf("component_id = $%d", argIdx))
			args = append(args, v)
			argIdx++
		}
		if v := strings.TrimSpace(filter.ParentID); v != "" {
			conditions = append(conditions, fmt.Sprintf("parent_id = $%d", argIdx))
			args = append(args, v)
			argIdx++
		}
		if len(filter.Types) > 0 {
			placeholders := make([]string, 0, len(filter.Types))
			for _, typ := range filter.Types {
				placeholders = append(placeholders, fmt.Sprintf("$%d", argIdx))
				args = append(args, string(typ))
				argIdx++
			}
			conditions = append(conditions, fmt.Sprintf("component_type IN (%s)", strings.Join(placeholders, ", ")))
		}
		if len(filter.Statuses) > 0 {
			placeholders := make([]string, 0, len(filter.Statuses))
			for _, st := range filter.Statuses {
				placeholders = append(placeholders, fmt.Sprintf("$%d", argIdx))
				args = append(args, string(st))
				argIdx++
			}
			conditions = append(conditions, fmt.Sprintf("status IN (%s)", strings.Join(placeholders, ", ")))
		}
	}

	queryBuilder.WriteString("SELECT DISTINCT ON (package_id) ")
	queryBuilder.WriteString(selectEdgePackageProjection())
	queryBuilder.WriteString("\nFROM edge_onboarding_packages")

	if len(conditions) > 0 {
		queryBuilder.WriteString("\nWHERE ")
		queryBuilder.WriteString(strings.Join(conditions, " AND "))
	}

	queryBuilder.WriteString("\nORDER BY package_id, updated_at DESC")

	limit := defaultEdgeOnboardingPackageLimit
	if filter != nil && filter.Limit > 0 {
		limit = filter.Limit
	}

	queryBuilder.WriteString(fmt.Sprintf("\nLIMIT $%d", argIdx))
	args = append(args, limit)

	rows, err := db.pgPool.Query(ctx, queryBuilder.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding packages: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var packages []*models.EdgeOnboardingPackage
	for rows.Next() {
		pkg, scanErr := scanEdgeOnboardingPackage(rows)
		if scanErr != nil {
			return nil, scanErr
		}
		packages = append(packages, pkg)
	}

	return packages, rows.Err()
}

// ListEdgeOnboardingPollerIDs returns poller IDs with packages in the supplied statuses.
func (db *DB) ListEdgeOnboardingPollerIDs(ctx context.Context, statuses ...models.EdgeOnboardingStatus) ([]string, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	args := []interface{}{}
	argIdx := 1
	conditions := []string{"component_type = 'poller'"}

	if len(statuses) > 0 {
		placeholders := make([]string, 0, len(statuses))
		for _, st := range statuses {
			placeholders = append(placeholders, fmt.Sprintf("$%d", argIdx))
			args = append(args, string(st))
			argIdx++
		}
		conditions = append(conditions, fmt.Sprintf("status IN (%s)", strings.Join(placeholders, ", ")))
	}

	query := "SELECT DISTINCT poller_id FROM edge_onboarding_packages"
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " AND ")
	}

	rows, err := db.pgPool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding poller ids: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var pollerIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("%w edge onboarding poller id: %w", ErrFailedToScan, err)
		}
		if strings.TrimSpace(id) != "" {
			pollerIDs = append(pollerIDs, id)
		}
	}

	return pollerIDs, rows.Err()
}

// InsertEdgeOnboardingEvent records a package event.
func (db *DB) InsertEdgeOnboardingEvent(ctx context.Context, event *models.EdgeOnboardingEvent) error {
	if event == nil {
		return ErrEdgeEventNil
	}

	return db.cnpgInsertEdgeOnboardingEvent(ctx, event)
}

// ListEdgeOnboardingEvents lists events for a package.
func (db *DB) ListEdgeOnboardingEvents(ctx context.Context, packageID string, limit int) ([]*models.EdgeOnboardingEvent, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	parsed, err := uuid.Parse(strings.TrimSpace(packageID))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid package_id %q: %w", ErrEdgePackageInvalid, packageID, err)
	}

	if limit <= 0 {
		limit = 50
	}

	rows, err := db.pgPool.Query(ctx, `
        SELECT event_time, event_type, actor, source_ip, details_json
        FROM edge_onboarding_events
        WHERE package_id = $1
        ORDER BY event_time DESC
        LIMIT $2`, parsed, limit)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding events: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var events []*models.EdgeOnboardingEvent
	for rows.Next() {
		var ev models.EdgeOnboardingEvent
		ev.PackageID = packageID
		if err := rows.Scan(&ev.EventTime, &ev.EventType, &ev.Actor, &ev.SourceIP, &ev.DetailsJSON); err != nil {
			return nil, fmt.Errorf("%w edge onboarding event: %w", ErrFailedToScan, err)
		}
		events = append(events, &ev)
	}

	return events, rows.Err()
}

// DeleteEdgeOnboardingPackage records a tombstone row for the supplied package.
func (db *DB) DeleteEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil {
		return fmt.Errorf("%w: edge onboarding package is nil", ErrEdgePackageInvalid)
	}

	pkg.Status = models.EdgeOnboardingStatusDeleted
	now := timeNowUTC()
	pkg.DeletedAt = &now
	pkg.DeletedBy = strings.TrimSpace(pkg.DeletedBy)
	if pkg.DeletedBy == "" {
		pkg.DeletedBy = "system"
	}

	return db.UpsertEdgeOnboardingPackage(ctx, pkg)
}

func scanEdgeOnboardingPackage(row pgx.Row) (*models.EdgeOnboardingPackage, error) {
	var pkg models.EdgeOnboardingPackage
	var (
		packageID       uuid.UUID
		componentType   string
		parentType      string
		status          string
		checkerConfig   []byte
		metadataJSON    []byte
		selectors       []string
		activatedFromIP *string
		lastSeenSPIFFE  *string
		deliveredAt     *time.Time
		activatedAt     *time.Time
		revokedAt       *time.Time
		deletedAt       *time.Time
	)

	if err := row.Scan(
		&packageID,
		&pkg.Label,
		&pkg.ComponentID,
		&componentType,
		&parentType,
		&pkg.ParentID,
		&pkg.PollerID,
		&pkg.Site,
		&status,
		&pkg.DownstreamEntryID,
		&pkg.DownstreamSPIFFEID,
		&selectors,
		&pkg.CheckerKind,
		&checkerConfig,
		&pkg.JoinTokenCiphertext,
		&pkg.JoinTokenExpiresAt,
		&pkg.BundleCiphertext,
		&pkg.DownloadTokenHash,
		&pkg.DownloadTokenExpiresAt,
		&pkg.CreatedBy,
		&pkg.CreatedAt,
		&pkg.UpdatedAt,
		&deliveredAt,
		&activatedAt,
		&activatedFromIP,
		&lastSeenSPIFFE,
		&revokedAt,
		&deletedAt,
		&pkg.DeletedBy,
		&pkg.DeletedReason,
		&metadataJSON,
		&pkg.KVRevision,
		&pkg.Notes,
	); err != nil {
		return nil, fmt.Errorf("%w edge onboarding package row: %w", ErrFailedToScan, err)
	}

	pkg.PackageID = packageID.String()
	pkg.ComponentType = models.EdgeOnboardingComponentType(strings.TrimSpace(componentType))
	pkg.ParentType = models.EdgeOnboardingComponentType(strings.TrimSpace(parentType))
	pkg.Status = models.EdgeOnboardingStatus(strings.TrimSpace(status))
	pkg.Selectors = selectors
	pkg.CheckerConfigJSON = string(checkerConfig)
	pkg.MetadataJSON = string(metadataJSON)
	pkg.ActivatedFromIP = activatedFromIP
	pkg.LastSeenSPIFFEID = lastSeenSPIFFE
	pkg.DeliveredAt = deliveredAt
	pkg.ActivatedAt = activatedAt
	pkg.RevokedAt = revokedAt
	pkg.DeletedAt = deletedAt

	return &pkg, nil
}

func timeNowUTC() time.Time {
	return time.Now().UTC()
}
