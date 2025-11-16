package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const upsertEdgePackageSQL = `
INSERT INTO edge_onboarding_packages (
	package_id,
	label,
	component_id,
	component_type,
	parent_type,
	parent_id,
	poller_id,
	site,
	status,
	downstream_entry_id,
	downstream_spiffe_id,
	selectors,
	checker_kind,
	checker_config_json,
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
	notes
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33
)
ON CONFLICT (package_id) DO UPDATE SET
	label = EXCLUDED.label,
	component_id = EXCLUDED.component_id,
	component_type = EXCLUDED.component_type,
	parent_type = EXCLUDED.parent_type,
	parent_id = EXCLUDED.parent_id,
	poller_id = EXCLUDED.poller_id,
	site = EXCLUDED.site,
	status = EXCLUDED.status,
	downstream_entry_id = EXCLUDED.downstream_entry_id,
	downstream_spiffe_id = EXCLUDED.downstream_spiffe_id,
	selectors = EXCLUDED.selectors,
	checker_kind = EXCLUDED.checker_kind,
	checker_config_json = EXCLUDED.checker_config_json,
	join_token_ciphertext = EXCLUDED.join_token_ciphertext,
	join_token_expires_at = EXCLUDED.join_token_expires_at,
	bundle_ciphertext = EXCLUDED.bundle_ciphertext,
	download_token_hash = EXCLUDED.download_token_hash,
	download_token_expires_at = EXCLUDED.download_token_expires_at,
	created_by = EXCLUDED.created_by,
	created_at = EXCLUDED.created_at,
	updated_at = EXCLUDED.updated_at,
	delivered_at = EXCLUDED.delivered_at,
	activated_at = EXCLUDED.activated_at,
	activated_from_ip = EXCLUDED.activated_from_ip,
	last_seen_spiffe_id = EXCLUDED.last_seen_spiffe_id,
	revoked_at = EXCLUDED.revoked_at,
	deleted_at = EXCLUDED.deleted_at,
	deleted_by = EXCLUDED.deleted_by,
	deleted_reason = EXCLUDED.deleted_reason,
	metadata_json = EXCLUDED.metadata_json,
	kv_revision = EXCLUDED.kv_revision,
	notes = EXCLUDED.notes`

const insertEdgeEventSQL = `
INSERT INTO edge_onboarding_events (
	event_time,
	package_id,
	event_type,
	actor,
	source_ip,
	details_json
) VALUES (
	$1,$2,$3,$4,$5,$6
)`

func (db *DB) cnpgUpsertEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil || !db.useCNPGWrites() {
		return nil
	}

	args, err := buildEdgeOnboardingPackageArgs(pkg)
	if err != nil {
		return err
	}

	batch := &pgx.Batch{}
	batch.Queue(upsertEdgePackageSQL, args...)

	return db.sendCNPG(ctx, batch, "edge onboarding package")
}

func (db *DB) cnpgInsertEdgeOnboardingEvent(ctx context.Context, event *models.EdgeOnboardingEvent) error {
	if event == nil || !db.useCNPGWrites() {
		return nil
	}

	args, err := buildEdgeOnboardingEventArgs(event)
	if err != nil {
		return err
	}

	batch := &pgx.Batch{}
	batch.Queue(insertEdgeEventSQL, args...)

	return db.sendCNPG(ctx, batch, "edge onboarding event")
}

func buildEdgeOnboardingPackageArgs(pkg *models.EdgeOnboardingPackage) ([]interface{}, error) {
	if pkg == nil {
		return nil, fmt.Errorf("%w: package is nil", ErrEdgePackageInvalid)
	}

	packageID := strings.TrimSpace(pkg.PackageID)
	if packageID == "" {
		return nil, ErrEdgePackageIDRequired
	}

	parsedID, err := uuid.Parse(packageID)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding package id invalid: %w", err)
	}

	metadata, err := normalizeJSON(pkg.MetadataJSON)
	if err != nil {
		return nil, fmt.Errorf("metadata_json: %w", err)
	}

	checkerConfig, err := normalizeJSON(pkg.CheckerConfigJSON)
	if err != nil {
		return nil, fmt.Errorf("checker_config_json: %w", err)
	}

	selectors := pkg.Selectors
	if selectors == nil {
		selectors = []string{}
	}

	return []interface{}{
		parsedID,
		pkg.Label,
		pkg.ComponentID,
		string(pkg.ComponentType),
		string(pkg.ParentType),
		pkg.ParentID,
		pkg.PollerID,
		pkg.Site,
		string(pkg.Status),
		pkg.DownstreamEntryID,
		pkg.DownstreamSPIFFEID,
		selectors,
		pkg.CheckerKind,
		defaultJSONRaw(checkerConfig),
		pkg.JoinTokenCiphertext,
		normalizeRequiredTime(pkg.JoinTokenExpiresAt),
		pkg.BundleCiphertext,
		pkg.DownloadTokenHash,
		normalizeRequiredTime(pkg.DownloadTokenExpiresAt),
		pkg.CreatedBy,
		normalizeRequiredTime(pkg.CreatedAt),
		normalizeRequiredTime(pkg.UpdatedAt),
		toNullableTime(pkg.DeliveredAt),
		toNullableTime(pkg.ActivatedAt),
		toNullableString(pkg.ActivatedFromIP),
		toNullableString(pkg.LastSeenSPIFFEID),
		toNullableTime(pkg.RevokedAt),
		toNullableTime(pkg.DeletedAt),
		strings.TrimSpace(pkg.DeletedBy),
		strings.TrimSpace(pkg.DeletedReason),
		defaultJSONRaw(metadata),
		int64(pkg.KVRevision),
		pkg.Notes,
	}, nil
}

func buildEdgeOnboardingEventArgs(event *models.EdgeOnboardingEvent) ([]interface{}, error) {
	if event == nil {
		return nil, ErrEdgeEventNil
	}

	parsedID, err := uuid.Parse(strings.TrimSpace(event.PackageID))
	if err != nil {
		return nil, fmt.Errorf("edge onboarding event package id invalid: %w", err)
	}

	details, err := normalizeJSON(event.DetailsJSON)
	if err != nil {
		return nil, fmt.Errorf("event details json: %w", err)
	}

	return []interface{}{
		normalizeRequiredTime(event.EventTime),
		parsedID,
		event.EventType,
		strings.TrimSpace(event.Actor),
		strings.TrimSpace(event.SourceIP),
		defaultJSONRaw(details),
	}, nil
}

func normalizeRequiredTime(ts time.Time) time.Time {
	if ts.IsZero() {
		return nowUTC()
	}

	return ts.UTC()
}

func toNullableTime(ts *time.Time) interface{} {
	if ts == nil || ts.IsZero() {
		return nil
	}
	return ts.UTC()
}

func defaultJSONRaw(value interface{}) interface{} {
	if value == nil {
		return json.RawMessage(`{}`)
	}
	return value
}
