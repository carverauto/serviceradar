package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const insertNetflowSQL = `
INSERT INTO netflow_metrics (
    timestamp,
    poller_id,
    agent_id,
    device_id,
    flow_direction,
    src_addr,
    dst_addr,
    src_port,
    dst_port,
    protocol,
    packets,
    octets,
    sampler_address,
    input_snmp,
    output_snmp,
    metadata
) VALUES (
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16
)`

func (db *DB) cnpgInsertNetflowMetrics(ctx context.Context, metrics []*models.NetflowMetric) error {
	if len(metrics) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, metric := range metrics {
		args, err := buildNetflowMetricArgs(metric)
		if err != nil {
			db.logger.Warn().Err(err).
				Str("src_addr", safeStringValue(metric, func(m *models.NetflowMetric) string { return m.SrcAddr })).
				Msg("skipping netflow metric")
			continue
		}
		batch.Queue(insertNetflowSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "netflow metrics")
}

func buildNetflowMetricArgs(metric *models.NetflowMetric) ([]interface{}, error) {
	if metric == nil {
		return nil, fmt.Errorf("netflow metric is nil")
	}

	metadata, err := normalizeJSON(metric.Metadata)
	if err != nil {
		return nil, fmt.Errorf("metadata: %w", err)
	}

	return []interface{}{
		sanitizeTimestamp(metric.Timestamp),
		"", // poller_id (not provided today)
		"", // agent_id
		"", // device_id
		"", // flow_direction
		metric.SrcAddr,
		metric.DstAddr,
		metric.SrcPort,
		metric.DstPort,
		metric.Protocol,
		int64(metric.Packets),
		int64(metric.Bytes),
		metric.SamplerAddress,
		int32(0), // input_snmp
		int32(0), // output_snmp
		metadata,
	}, nil
}

func safeStringValue(metric *models.NetflowMetric, getter func(*models.NetflowMetric) string) string {
	if metric == nil {
		return ""
	}
	return getter(metric)
}
