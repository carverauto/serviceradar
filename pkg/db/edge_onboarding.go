package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultEdgeOnboardingPackageLimit = 100

	edgeOnboardingPackagesSelectClause = `
SELECT
	package_id,
		arg_max(label, updated_at) AS label,
		arg_max(component_id, updated_at) AS component_id,
		arg_max(component_type, updated_at) AS component_type,
		arg_max(parent_type, updated_at) AS parent_type,
		arg_max(parent_id, updated_at) AS parent_id,
		arg_max(poller_id, updated_at) AS poller_id,
		arg_max(site, updated_at) AS site,
		arg_max(status, updated_at) AS status,
		arg_max(downstream_entry_id, updated_at) AS downstream_entry_id,
		arg_max(downstream_spiffe_id, updated_at) AS downstream_spiffe_id,
		arg_max(selectors, updated_at) AS selectors,
		arg_max(join_token_ciphertext, updated_at) AS join_token_ciphertext,
		arg_max(join_token_expires_at, updated_at) AS join_token_expires_at,
		arg_max(bundle_ciphertext, updated_at) AS bundle_ciphertext,
		arg_max(download_token_hash, updated_at) AS download_token_hash,
		arg_max(download_token_expires_at, updated_at) AS download_token_expires_at,
		arg_max(created_by, updated_at) AS created_by,
		arg_max(created_at, updated_at) AS created_at,
		max(updated_at) AS latest_updated_at,
		arg_max(delivered_at, updated_at) AS delivered_at,
		arg_max(activated_at, updated_at) AS activated_at,
		arg_max(activated_from_ip, updated_at) AS activated_from_ip,
		arg_max(last_seen_spiffe_id, updated_at) AS last_seen_spiffe_id,
		arg_max(revoked_at, updated_at) AS revoked_at,
		arg_max(deleted_at, updated_at) AS deleted_at,
		arg_max(deleted_by, updated_at) AS deleted_by,
		arg_max(deleted_reason, updated_at) AS deleted_reason,
		arg_max(metadata_json, updated_at) AS metadata_json,
		arg_max(checker_kind, updated_at) AS checker_kind,
		arg_max(checker_config_json, updated_at) AS checker_config_json,
		arg_max(kv_revision, updated_at) AS kv_revision,
		arg_max(notes, updated_at) AS notes
FROM filtered`
)

// UpsertEdgeOnboardingPackage inserts or replaces an onboarding package row.
func (db *DB) UpsertEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil {
		return fmt.Errorf("%w: edge onboarding package is nil", ErrEdgePackageInvalid)
	}

	packageUUID, err := uuid.Parse(pkg.PackageID)
	if err != nil {
		return fmt.Errorf("%w: invalid package_id %q: %w", ErrEdgePackageInvalid, pkg.PackageID, err)
	}

	selectors := pkg.Selectors
	if selectors == nil {
		selectors = []string{}
	}

	values := []any{
		packageUUID,
		pkg.Label,
		pkg.ComponentID,
		string(pkg.ComponentType),
		string(pkg.ParentType),
		pkg.ParentID,
		pkg.CheckerKind,
		pkg.CheckerConfigJSON,
		pkg.PollerID,
		pkg.Site,
		string(pkg.Status),
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
		optionalTime(pkg.DeletedAt),
		strings.TrimSpace(pkg.DeletedBy),
		strings.TrimSpace(pkg.DeletedReason),
		pkg.MetadataJSON,
		pkg.KVRevision,
		pkg.Notes,
		pkg.DownstreamEntryID,
	}

	db.logger.Info().
		Str("package_id", pkg.PackageID).
		Int("column_count", len(values)).
		Str("component_type", string(pkg.ComponentType)).
		Msg("Upserting edge onboarding package row")

	return db.executeBatch(ctx, `
		INSERT INTO edge_onboarding_packages (
			package_id,
			label,
			component_id,
			component_type,
			parent_type,
			parent_id,
			checker_kind,
			checker_config_json,
			poller_id,
			site,
			status,
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
			deleted_at,
			deleted_by,
			deleted_reason,
			metadata_json,
			kv_revision,
			notes,
			downstream_entry_id
		) VALUES`, func(batch driver.Batch) error {
		return batch.Append(values...)
	})
}

// GetEdgeOnboardingPackage fetches a single onboarding package by ID.
func (db *DB) GetEdgeOnboardingPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error) {
	packageUUID, err := uuid.Parse(packageID)
	if err != nil {
		return nil, fmt.Errorf("%w: invalid package_id %q: %w", ErrEdgePackageInvalid, packageID, err)
	}

	query, args := buildEdgeOnboardingPackagesQuery(edgeOnboardingQueryOptions{
		PackageID: &packageUUID,
		Limit:     1,
	})

	rows, err := db.Conn.Query(ctx, query, args...)
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
	query, args := buildEdgeOnboardingPackagesQuery(edgeOnboardingQueryOptions{
		Filter: filter,
	})

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

type edgeOnboardingQueryOptions struct {
	PackageID *uuid.UUID
	Filter    *models.EdgeOnboardingListFilter
	Limit     int
}

type edgeOnboardingQueryBuilder struct {
	args       []interface{}
	conditions []string
}

func (b *edgeOnboardingQueryBuilder) param(value interface{}) string {
	b.args = append(b.args, value)
	return fmt.Sprintf("$%d", len(b.args))
}

func buildEdgeOnboardingPackagesQuery(opts edgeOnboardingQueryOptions) (string, []interface{}) {
	builder := &edgeOnboardingQueryBuilder{
		args:       make([]interface{}, 0, 8),
		conditions: make([]string, 0, 6),
	}

	if opts.PackageID != nil {
		builder.conditions = append(builder.conditions, fmt.Sprintf("package_id = %s", builder.param(*opts.PackageID)))
	}

	if filter := opts.Filter; filter != nil {
		if filter.PollerID != "" {
			builder.conditions = append(builder.conditions, fmt.Sprintf("poller_id = %s", builder.param(filter.PollerID)))
		}
		if filter.ComponentID != "" {
			builder.conditions = append(builder.conditions, fmt.Sprintf("component_id = %s", builder.param(filter.ComponentID)))
		}
		if filter.ParentID != "" {
			builder.conditions = append(builder.conditions, fmt.Sprintf("parent_id = %s", builder.param(filter.ParentID)))
		}

		if len(filter.Types) > 0 {
			typePlaceholders := make([]string, 0, len(filter.Types))
			for _, typ := range filter.Types {
				typePlaceholders = append(typePlaceholders, builder.param(string(typ)))
			}
			builder.conditions = append(builder.conditions, fmt.Sprintf("component_type IN (%s)", strings.Join(typePlaceholders, ", ")))
		}

		if len(filter.Statuses) > 0 {
			statusPlaceholders := make([]string, 0, len(filter.Statuses))
			for _, st := range filter.Statuses {
				statusPlaceholders = append(statusPlaceholders, builder.param(string(st)))
			}
			builder.conditions = append(builder.conditions, fmt.Sprintf("status IN (%s)", strings.Join(statusPlaceholders, ", ")))
		}
	}

	limit := opts.Limit
	if limit <= 0 {
		if filter := opts.Filter; filter != nil && filter.Limit > 0 {
			limit = filter.Limit
		}
	}
	if limit <= 0 {
		limit = defaultEdgeOnboardingPackageLimit
	}

	query := "WITH filtered AS (\n\tSELECT *\n\tFROM table(edge_onboarding_packages)"
	if len(builder.conditions) > 0 {
		query += "\n\tWHERE " + strings.Join(builder.conditions, " AND ")
	}
	query += "\n)"
	query += edgeOnboardingPackagesSelectClause
	query += "\nGROUP BY package_id"
	query += "\nORDER BY latest_updated_at DESC"
	query += fmt.Sprintf("\nLIMIT %s", builder.param(limit))

	return query, builder.args
}

// ListEdgeOnboardingPollerIDs returns poller IDs with packages in the supplied statuses.
func (db *DB) ListEdgeOnboardingPollerIDs(ctx context.Context, statuses ...models.EdgeOnboardingStatus) ([]string, error) {
	statusStrings := make([]string, 0, len(statuses))
	for _, st := range statuses {
		statusStrings = append(statusStrings, string(st))
	}

	query := `
		SELECT poller_id, _tp_delta
		FROM table(edge_onboarding_packages) FINAL`

	var conditions []string
	if len(statusStrings) > 0 {
		literals := make([]string, 0, len(statusStrings))
		for _, st := range statusStrings {
			literals = append(literals, fmt.Sprintf("'%s'", st))
		}
		conditions = append(conditions, fmt.Sprintf("status IN (%s)", strings.Join(literals, ", ")))
	}

	conditions = append(conditions, "component_type = 'poller'")

	if len(conditions) > 0 {
		query += "\nWHERE " + strings.Join(conditions, " AND ")
	}

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding pollers: %w", ErrFailedToQuery, err)
	}
	defer db.CloseRows(rows)

	var pollerIDs []string
	for rows.Next() {
		var (
			id    string
			delta int8
		)
		if err := rows.Scan(&id, &delta); err != nil {
			return nil, fmt.Errorf("%w edge onboarding poller id: %w", ErrFailedToScan, err)
		}
		if delta <= 0 {
			continue
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

	packageUUID, err := uuid.Parse(event.PackageID)
	if err != nil {
		return fmt.Errorf("%w: invalid package_id %q: %w", ErrEdgePackageInvalid, event.PackageID, err)
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
			packageUUID,
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

	packageUUID, err := uuid.Parse(packageID)
	if err != nil {
		return nil, fmt.Errorf("%w: invalid package_id %q: %w", ErrEdgePackageInvalid, packageID, err)
	}

	rows, err := db.Conn.Query(ctx, `
		SELECT
			event_time,
			event_type,
			actor,
			source_ip,
			details_json
		FROM table(edge_onboarding_events)
		WHERE package_id = $1
		ORDER BY event_time DESC
		LIMIT $2`,
		packageUUID, limit)
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

// DeleteEdgeOnboardingPackage records a tombstone row for the supplied package.
func (db *DB) DeleteEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil {
		return fmt.Errorf("%w: edge onboarding package is nil", ErrEdgePackageInvalid)
	}

	if strings.TrimSpace(pkg.PackageID) == "" {
		return fmt.Errorf("%w: package_id is required", ErrEdgePackageInvalid)
	}

	if pkg.Status != models.EdgeOnboardingStatusDeleted {
		pkg.Status = models.EdgeOnboardingStatusDeleted
	}

	return db.UpsertEdgeOnboardingPackage(ctx, pkg)
}

func scanEdgeOnboardingPackage(rows Rows) (*models.EdgeOnboardingPackage, error) {
	var pkg models.EdgeOnboardingPackage

	var (
		packageUUID      uuid.UUID
		componentID      string
		componentType    string
		parentType       string
		parentID         string
		deliveredAt      *time.Time
		activatedAt      *time.Time
		revokedAt        *time.Time
		deletedAt        *time.Time
		deletedBy        string
		deletedReason    string
		activatedFromIP  *string
		lastSeenSPIFFEID *string
		checkerKind      string
		checkerConfig    string
		kvRevision       uint64
		status           string
	)

	err := rows.Scan(
		&packageUUID,
		&pkg.Label,
		&componentID,
		&componentType,
		&parentType,
		&parentID,
		&pkg.PollerID,
		&pkg.Site,
		&status,
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
		&deletedAt,
		&deletedBy,
		&deletedReason,
		&pkg.MetadataJSON,
		&checkerKind,
		&checkerConfig,
		&kvRevision,
		&pkg.Notes,
	)
	if err != nil {
		return nil, fmt.Errorf("%w edge onboarding package row: %w", ErrFailedToScan, err)
	}

	pkg.PackageID = packageUUID.String()
	pkg.ComponentID = componentID
	pkg.ComponentType = models.EdgeOnboardingComponentType(componentType)
	pkg.ParentType = models.EdgeOnboardingComponentType(parentType)
	pkg.ParentID = parentID
	pkg.Status = models.EdgeOnboardingStatus(status)
	pkg.DeliveredAt = deliveredAt
	pkg.ActivatedAt = activatedAt
	pkg.RevokedAt = revokedAt
	pkg.DeletedAt = deletedAt
	pkg.DeletedBy = deletedBy
	pkg.DeletedReason = deletedReason
	pkg.ActivatedFromIP = activatedFromIP
	pkg.LastSeenSPIFFEID = lastSeenSPIFFEID
	pkg.CheckerKind = checkerKind
	pkg.CheckerConfigJSON = checkerConfig
	pkg.KVRevision = kvRevision

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
