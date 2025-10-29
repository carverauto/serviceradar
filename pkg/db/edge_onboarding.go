package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"

	"github.com/carverauto/serviceradar/pkg/models"
)

// UpsertEdgeOnboardingPackage inserts or replaces an onboarding package row.
func (db *DB) UpsertEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil {
		return fmt.Errorf("%w: edge onboarding package is nil", ErrEdgePackageInvalid)
	}

	selectors := pkg.Selectors
	if selectors == nil {
		selectors = []string{}
	}

	return db.executeBatch(ctx, `
		INSERT INTO edge_onboarding_packages (
			package_id,
			label,
			poller_id,
			site,
			status,
			downstream_entry_id,
			downstream_spiffe_id,
			selectors,
			join_token_ciphertext,
			join_token_expires_at,
			bundle_ciphertext,
			download_token_hash,
			download_token_expires_at,
			created_by,
			created_at,
			updated_at,
			delivered_at,
			activated_at,
			activated_from_ip,
			last_seen_spiffe_id,
			revoked_at,
			metadata_json,
			notes
		) VALUES`, func(batch driver.Batch) error {
		return batch.Append(
			pkg.PackageID,
			pkg.Label,
			pkg.PollerID,
			pkg.Site,
			string(pkg.Status),
			pkg.DownstreamEntryID,
			pkg.DownstreamSPIFFEID,
			selectors,
			pkg.JoinTokenCiphertext,
			pkg.JoinTokenExpiresAt,
			pkg.BundleCiphertext,
			pkg.DownloadTokenHash,
			pkg.DownloadTokenExpiresAt,
			pkg.CreatedBy,
			pkg.CreatedAt,
			pkg.UpdatedAt,
			optionalTime(pkg.DeliveredAt),
			optionalTime(pkg.ActivatedAt),
			optionalString(pkg.ActivatedFromIP),
			optionalString(pkg.LastSeenSPIFFEID),
			optionalTime(pkg.RevokedAt),
			pkg.MetadataJSON,
			pkg.Notes,
		)
	})
}

// GetEdgeOnboardingPackage fetches a single onboarding package by ID.
func (db *DB) GetEdgeOnboardingPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT
			package_id,
			label,
			poller_id,
			site,
			status,
			downstream_entry_id,
			downstream_spiffe_id,
			selectors,
			join_token_ciphertext,
			join_token_expires_at,
			bundle_ciphertext,
			download_token_hash,
			download_token_expires_at,
			created_by,
			created_at,
			updated_at,
			delivered_at,
			activated_at,
			activated_from_ip,
			last_seen_spiffe_id,
			revoked_at,
			metadata_json,
			notes
		FROM edge_onboarding_packages
		WHERE package_id = $1
		LIMIT 1`,
		packageID)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding package: %w", ErrFailedToQuery, err)
	}
	defer db.CloseRows(rows)

	if !rows.Next() {
		return nil, fmt.Errorf("%w: %s", ErrEdgePackageNotFound, packageID)
	}

	return scanEdgeOnboardingPackage(rows)
}

// ListEdgeOnboardingPackages returns packages filtered by optional criteria.
func (db *DB) ListEdgeOnboardingPackages(ctx context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
	query := `
		SELECT
			package_id,
			label,
			poller_id,
			site,
			status,
			downstream_entry_id,
			downstream_spiffe_id,
			selectors,
			join_token_ciphertext,
			join_token_expires_at,
			bundle_ciphertext,
			download_token_hash,
			download_token_expires_at,
			created_by,
			created_at,
			updated_at,
			delivered_at,
			activated_at,
			activated_from_ip,
			last_seen_spiffe_id,
			revoked_at,
			metadata_json,
			notes
		FROM edge_onboarding_packages`

	var (
		args       []interface{}
		conditions []string
	)

	param := func(value interface{}) string {
		args = append(args, value)
		return fmt.Sprintf("$%d", len(args))
	}

	if filter != nil {
		if filter.PollerID != "" {
			conditions = append(conditions, fmt.Sprintf("poller_id = %s", param(filter.PollerID)))
		}

		if len(filter.Statuses) > 0 {
			statuses := make([]string, 0, len(filter.Statuses))
			for _, st := range filter.Statuses {
				statuses = append(statuses, string(st))
			}
			conditions = append(conditions, fmt.Sprintf("status IN %s", param(statuses)))
		}
	}

	if len(conditions) > 0 {
		query += "\nWHERE " + strings.Join(conditions, " AND ")
	}

	query += "\nORDER BY updated_at DESC"

	limit := 100
	if filter != nil && filter.Limit > 0 {
		limit = filter.Limit
	}

	query += fmt.Sprintf("\nLIMIT %s", param(limit))

	rows, err := db.Conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding packages: %w", ErrFailedToQuery, err)
	}
	defer db.CloseRows(rows)

	var packages []*models.EdgeOnboardingPackage

	for rows.Next() {
		pkg, scanErr := scanEdgeOnboardingPackage(rows)
		if scanErr != nil {
			return nil, scanErr
		}
		packages = append(packages, pkg)
	}

	return packages, nil
}

// ListEdgeOnboardingPollerIDs returns poller IDs with packages in the supplied statuses.
func (db *DB) ListEdgeOnboardingPollerIDs(ctx context.Context, statuses ...models.EdgeOnboardingStatus) ([]string, error) {
	statusStrings := make([]string, 0, len(statuses))
	for _, st := range statuses {
		statusStrings = append(statusStrings, string(st))
	}

	query := `
		SELECT DISTINCT poller_id
		FROM edge_onboarding_packages FINAL`

	var (
		args       []interface{}
		conditions []string
	)

	param := func(value interface{}) string {
		args = append(args, value)
		return fmt.Sprintf("$%d", len(args))
	}

	if len(statusStrings) > 0 {
		conditions = append(conditions, fmt.Sprintf("status IN %s", param(statusStrings)))
	}

	if len(conditions) > 0 {
		query += "\nWHERE " + strings.Join(conditions, " AND ")
	}

	rows, err := db.Conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding pollers: %w", ErrFailedToQuery, err)
	}
	defer db.CloseRows(rows)

	var pollerIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("%w edge onboarding poller id: %w", ErrFailedToScan, err)
		}
		pollerIDs = append(pollerIDs, id)
	}

	return pollerIDs, nil
}

// InsertEdgeOnboardingEvent appends an audit record for a package.
func (db *DB) InsertEdgeOnboardingEvent(ctx context.Context, event *models.EdgeOnboardingEvent) error {
	if event == nil {
		return fmt.Errorf("%w: edge onboarding event is nil", ErrEdgePackageInvalid)
	}

	return db.executeBatch(ctx, `
		INSERT INTO edge_onboarding_events (
			event_time,
			package_id,
			event_type,
			actor,
			source_ip,
			details_json
		) VALUES`, func(batch driver.Batch) error {
		return batch.Append(
			event.EventTime,
			event.PackageID,
			event.EventType,
			event.Actor,
			event.SourceIP,
			event.DetailsJSON,
		)
	})
}

// ListEdgeOnboardingEvents fetches audit events for a package ordered by time descending.
func (db *DB) ListEdgeOnboardingEvents(ctx context.Context, packageID string, limit int) ([]*models.EdgeOnboardingEvent, error) {
	if limit <= 0 {
		limit = 100
	}

	rows, err := db.Conn.Query(ctx, `
		SELECT
			event_time,
			event_type,
			actor,
			source_ip,
			details_json
		FROM edge_onboarding_events
		WHERE package_id = $1
		ORDER BY event_time DESC
		LIMIT $2`,
		packageID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding events: %w", ErrFailedToQuery, err)
	}
	defer db.CloseRows(rows)

	var events []*models.EdgeOnboardingEvent
	for rows.Next() {
		var ev models.EdgeOnboardingEvent
		ev.PackageID = packageID
		if err := rows.Scan(
			&ev.EventTime,
			&ev.EventType,
			&ev.Actor,
			&ev.SourceIP,
			&ev.DetailsJSON,
		); err != nil {
			return nil, fmt.Errorf("%w edge onboarding event: %w", ErrFailedToScan, err)
		}
		events = append(events, &ev)
	}

	return events, nil
}

func scanEdgeOnboardingPackage(rows Rows) (*models.EdgeOnboardingPackage, error) {
	var pkg models.EdgeOnboardingPackage

	var (
		deliveredAt      *time.Time
		activatedAt      *time.Time
		revokedAt        *time.Time
		activatedFromIP  *string
		lastSeenSPIFFEID *string
	)

	err := rows.Scan(
		&pkg.PackageID,
		&pkg.Label,
		&pkg.PollerID,
		&pkg.Site,
		&pkg.Status,
		&pkg.DownstreamEntryID,
		&pkg.DownstreamSPIFFEID,
		&pkg.Selectors,
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
		&lastSeenSPIFFEID,
		&revokedAt,
		&pkg.MetadataJSON,
		&pkg.Notes,
	)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding package row: %w", ErrFailedToScan, err)
	}

	pkg.DeliveredAt = deliveredAt
	pkg.ActivatedAt = activatedAt
	pkg.RevokedAt = revokedAt
	pkg.ActivatedFromIP = activatedFromIP
	pkg.LastSeenSPIFFEID = lastSeenSPIFFEID

	return &pkg, nil
}

func optionalTime(t *time.Time) interface{} {
	if t == nil {
		return nil
	}
	return *t
}

func optionalString(s *string) interface{} {
	if s == nil {
		return nil
	}
	return *s
}
