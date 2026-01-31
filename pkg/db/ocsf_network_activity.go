package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const defaultOCSFNetworkActivityTable = "ocsf_network_activity"

func buildOCSFNetworkActivityInsertQuery(table string) string {
	return fmt.Sprintf(`INSERT INTO %s (
		time,
		class_uid,
		category_uid,
		activity_id,
		type_uid,
		severity_id,
		start_time,
		end_time,
		src_endpoint_ip,
		src_endpoint_port,
		src_as_number,
		dst_endpoint_ip,
		dst_endpoint_port,
		dst_as_number,
		protocol_num,
		protocol_name,
		tcp_flags,
		bytes_total,
		packets_total,
		bytes_in,
		bytes_out,
		sampler_address,
		ocsf_payload,
		partition,
		created_at
	) VALUES (
		$1,$2,$3,$4,$5,$6,
		$7,$8,
		$9,$10,$11,
		$12,$13,$14,
		$15,$16,$17,
		$18,$19,$20,$21,
		$22,$23,$24,$25
	)`, table)
}

// InsertOCSFNetworkActivity persists OCSF network activity rows into the configured CNPG table.
func (db *DB) InsertOCSFNetworkActivity(ctx context.Context, table string, rows []models.OCSFNetworkActivity) error {
	if len(rows) == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrDatabaseNotInitialized
	}

	sanitizedTable, canonicalTable := sanitizeObservabilityTable(table, defaultOCSFNetworkActivityTable)
	query := buildOCSFNetworkActivityInsertQuery(sanitizedTable)

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for i := range rows {
		row := rows[i]

		ts := row.Time
		if ts.IsZero() {
			ts = now
		}

		createdAt := row.CreatedAt
		if createdAt.IsZero() {
			createdAt = now
		}

		partition := strings.TrimSpace(row.Partition)
		if partition == "" {
			partition = "default"
		}

		classUID := row.ClassUID
		if classUID == 0 {
			classUID = 4001
		}

		categoryUID := row.CategoryUID
		if categoryUID == 0 {
			categoryUID = 4
		}

		activityID := row.ActivityID
		if activityID == 0 {
			activityID = 6
		}

		typeUID := row.TypeUID
		if typeUID == 0 {
			typeUID = 400106
		}

		severityID := row.SeverityID
		if severityID == 0 {
			severityID = 1
		}

		payload := row.OCSFPayload
		if len(payload) == 0 {
			payload = json.RawMessage("{}")
		}

		batch.Queue(
			query,
			ts,
			classUID,
			categoryUID,
			activityID,
			typeUID,
			severityID,
			row.StartTime,
			row.EndTime,
			row.SrcEndpointIP,
			row.SrcEndpointPort,
			row.SrcASNumber,
			row.DstEndpointIP,
			row.DstEndpointPort,
			row.DstASNumber,
			row.ProtocolNum,
			row.ProtocolName,
			row.TCPFlags,
			row.BytesTotal,
			row.PacketsTotal,
			row.BytesIn,
			row.BytesOut,
			row.SamplerAddress,
			payload,
			partition,
			createdAt,
		)
	}

	if err := sendBatchExecAll(ctx, batch, db.conn().SendBatch, canonicalTable); err != nil {
		return fmt.Errorf("failed to insert ocsf network activity: %w", err)
	}

	return nil
}
