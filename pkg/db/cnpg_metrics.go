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

// nowUTC allows tests to override the timestamp source.
//
//nolint:gochecknoglobals // test hooks need a package-level clock override.
var nowUTC = func() time.Time {
	return time.Now().UTC()
}

const (
	insertTimeseriesMetricsSQL = `
INSERT INTO public.timeseries_metrics (
	timestamp,
	gateway_id,
	agent_id,
	metric_name,
	metric_type,
	device_id,
	value,
	unit,
	tags,
	partition,
	scale,
	is_delta,
	target_device_ip,
	if_index,
	metadata
) VALUES (
	$1,$2,$3,$4,$5,
	$6,$7,$8,$9,$10,
	$11,$12,$13,$14,$15
)`

	insertCPUMetricsSQL = `
INSERT INTO public.cpu_metrics (
	timestamp,
	gateway_id,
	agent_id,
	host_id,
	core_id,
	usage_percent,
	frequency_hz,
	label,
	cluster,
	device_id,
	partition
) VALUES (
	$1,$2,$3,$4,$5,
	$6,$7,$8,$9,$10,$11
)`

	insertCPUClusterMetricsSQL = `
INSERT INTO public.cpu_cluster_metrics (
	timestamp,
	gateway_id,
	agent_id,
	host_id,
	cluster,
	frequency_hz,
	device_id,
	partition
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8
)`

	insertDiskMetricsSQL = `
INSERT INTO public.disk_metrics (
	timestamp,
	gateway_id,
	agent_id,
	host_id,
	mount_point,
	device_name,
	total_bytes,
	used_bytes,
	available_bytes,
	usage_percent,
	device_id,
	partition
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
)`

	insertMemoryMetricsSQL = `
INSERT INTO public.memory_metrics (
	timestamp,
	gateway_id,
	agent_id,
	host_id,
	total_bytes,
	used_bytes,
	available_bytes,
	usage_percent,
	device_id,
	partition
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10
)`

	insertProcessMetricsSQL = `
INSERT INTO public.process_metrics (
	timestamp,
	gateway_id,
	agent_id,
	host_id,
	pid,
	name,
	cpu_usage,
	memory_usage,
	status,
	start_time,
	device_id,
	partition
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
)`
)

func (db *DB) cnpgInsertTimeseriesMetrics(ctx context.Context, gatewayID string, metrics []*models.TimeseriesMetric) error {
	if len(metrics) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, metric := range metrics {
		if metric == nil {
			continue
		}

		args, err := buildTimeseriesMetricArgs(gatewayID, metric)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("gateway_id", gatewayID).
				Str("metric_name", metric.Name).
				Msg("skipping CNPG timeseries metric")
			continue
		}

		batch.Queue(insertTimeseriesMetricsSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "timeseries metrics")
}

func (db *DB) cnpgInsertCPUMetrics(
	ctx context.Context,
	gatewayID, agentID, hostID, deviceID, partition string,
	cpus []models.CPUMetric,
	timestamp time.Time,
) error {
	if len(cpus) == 0 || !db.useCNPGWrites() {
		db.logger.Info().
			Int("cpu_count", len(cpus)).
			Bool("cnpg_writes", db.useCNPGWrites()).
			Msg("cnpgInsertCPUMetrics: skipping (no cpus or writes disabled)")
		return nil
	}

	db.logger.Info().
		Str("gateway_id", gatewayID).
		Str("device_id", deviceID).
		Int("cpu_count", len(cpus)).
		Time("timestamp", timestamp).
		Msg("cnpgInsertCPUMetrics: building batch")

	batch := &pgx.Batch{}
	queued := 0

	for _, cpu := range cpus {
		args := buildCPUMetricArgs(gatewayID, agentID, hostID, deviceID, partition, cpu, timestamp)
		batch.Queue(insertCPUMetricsSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	db.logger.Info().
		Int("queued", queued).
		Msg("cnpgInsertCPUMetrics: sending batch")

	if err := db.sendCNPG(ctx, batch, "cpu metrics"); err != nil {
		db.logger.Error().
			Err(err).
			Str("device_id", deviceID).
			Int("cpu_count", len(cpus)).
			Msg("cnpgInsertCPUMetrics: batch insert failed")
		return err
	}

	db.logger.Info().
		Str("device_id", deviceID).
		Int("cpu_count", len(cpus)).
		Msg("cnpgInsertCPUMetrics: batch insert succeeded")

	return nil
}

func (db *DB) cnpgInsertCPUClusterMetrics(
	ctx context.Context,
	gatewayID, agentID, hostID, deviceID, partition string,
	clusters []models.CPUClusterMetric,
	timestamp time.Time,
) error {
	if len(clusters) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, cluster := range clusters {
		args := buildCPUClusterMetricArgs(gatewayID, agentID, hostID, deviceID, partition, cluster, timestamp)
		batch.Queue(insertCPUClusterMetricsSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "cpu cluster metrics")
}

func (db *DB) cnpgInsertDiskMetrics(
	ctx context.Context,
	gatewayID, agentID, hostID, deviceID, partition string,
	disks []models.DiskMetric,
	timestamp time.Time,
) error {
	if len(disks) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, disk := range disks {
		args := buildDiskMetricArgs(gatewayID, agentID, hostID, deviceID, partition, disk, timestamp)
		batch.Queue(insertDiskMetricsSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "disk metrics")
}

func (db *DB) cnpgInsertMemoryMetrics(
	ctx context.Context,
	gatewayID, agentID, hostID, deviceID, partition string,
	memory *models.MemoryMetric,
	timestamp time.Time,
) error {
	if memory == nil || !db.useCNPGWrites() {
		return nil
	}

	if memory.UsedBytes == 0 && memory.TotalBytes == 0 {
		return nil
	}

	args := buildMemoryMetricArgs(gatewayID, agentID, hostID, deviceID, partition, memory, timestamp)

	batch := &pgx.Batch{}
	batch.Queue(insertMemoryMetricsSQL, args...)

	return db.sendCNPG(ctx, batch, "memory metrics")
}

func (db *DB) cnpgInsertProcessMetrics(
	ctx context.Context,
	gatewayID, agentID, hostID, deviceID, partition string,
	processes []models.ProcessMetric,
	timestamp time.Time,
) error {
	if len(processes) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for i := range processes {
		args := buildProcessMetricArgs(gatewayID, agentID, hostID, deviceID, partition, &processes[i], timestamp)
		batch.Queue(insertProcessMetricsSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "process metrics")
}

func (db *DB) sendCNPG(ctx context.Context, batch *pgx.Batch, name string) (err error) {
	br := db.pgPool.SendBatch(ctx, batch)
	defer func() {
		if closeErr := br.Close(); closeErr != nil && err == nil {
			err = fmt.Errorf("cnpg %s batch close: %w", name, closeErr)
		}
	}()

	// Read results for each queued command to properly detect errors
	for i := 0; i < batch.Len(); i++ {
		if _, err = br.Exec(); err != nil {
			return fmt.Errorf("cnpg %s insert (command %d): %w", name, i, err)
		}
	}

	return nil
}

func buildTimeseriesMetricArgs(gatewayID string, metric *models.TimeseriesMetric) ([]interface{}, error) {
	if metric == nil {
		return nil, ErrTimeseriesMetricNil
	}

	metadata, err := normalizeJSON(metric.Metadata)
	if err != nil {
		return nil, fmt.Errorf("invalid metadata: %w", err)
	}

	ts := sanitizeTimestamp(metric.Timestamp)

	return []interface{}{
		ts,
		gatewayID,
		"", // agent_id is not set for these metrics today
		metric.Name,
		metric.Type,
		metric.DeviceID,
		convertValueToFloat64(metric.Value, metric.Name),
		"",                    // unit
		map[string]string{},   // tags (reserved)
		metric.Partition,      // partition
		1.0,                   // scale
		false,                 // is_delta
		metric.TargetDeviceIP, // target_device_ip
		metric.IfIndex,        // if_index
		metadata,              // metadata jsonb
	}, nil
}

func buildCPUMetricArgs(
	gatewayID, agentID, hostID, deviceID, partition string,
	cpu models.CPUMetric,
	timestamp time.Time,
) []interface{} {
	ts := sanitizeTimestamp(timestamp)

	return []interface{}{
		ts,
		gatewayID,
		agentID,
		hostID,
		cpu.CoreID,
		cpu.UsagePercent,
		cpu.FrequencyHz,
		cpu.Label,
		cpu.Cluster,
		deviceID,
		partition,
	}
}

func buildCPUClusterMetricArgs(
	gatewayID, agentID, hostID, deviceID, partition string,
	cluster models.CPUClusterMetric,
	timestamp time.Time,
) []interface{} {
	ts := sanitizeTimestamp(timestamp)

	return []interface{}{
		ts,
		gatewayID,
		agentID,
		hostID,
		cluster.Name,
		cluster.FrequencyHz,
		deviceID,
		partition,
	}
}

func buildDiskMetricArgs(
	gatewayID, agentID, hostID, deviceID, partition string,
	disk models.DiskMetric,
	timestamp time.Time,
) []interface{} {
	ts := sanitizeTimestamp(timestamp)

	available := uint64(0)
	if disk.TotalBytes > disk.UsedBytes {
		available = disk.TotalBytes - disk.UsedBytes
	}

	usagePercent := 0.0
	if disk.TotalBytes > 0 {
		usagePercent = (float64(disk.UsedBytes) / float64(disk.TotalBytes)) * 100.0
	}

	deviceName := disk.MountPoint

	return []interface{}{
		ts,
		gatewayID,
		agentID,
		hostID,
		disk.MountPoint,
		deviceName,
		int64(disk.TotalBytes),
		int64(disk.UsedBytes),
		int64(available),
		usagePercent,
		deviceID,
		partition,
	}
}

func buildMemoryMetricArgs(
	gatewayID, agentID, hostID, deviceID, partition string,
	memory *models.MemoryMetric,
	timestamp time.Time,
) []interface{} {
	ts := sanitizeTimestamp(timestamp)

	total := uint64(0)
	used := uint64(0)
	if memory != nil {
		total = memory.TotalBytes
		used = memory.UsedBytes
	}

	available := uint64(0)
	if total > used {
		available = total - used
	}

	usagePercent := 0.0
	if total > 0 {
		usagePercent = (float64(used) / float64(total)) * 100.0
	}

	return []interface{}{
		ts,
		gatewayID,
		agentID,
		hostID,
		int64(total),
		int64(used),
		int64(available),
		usagePercent,
		deviceID,
		partition,
	}
}

func buildProcessMetricArgs(
	gatewayID, agentID, hostID, deviceID, partition string,
	process *models.ProcessMetric,
	timestamp time.Time,
) []interface{} {
	ts := sanitizeTimestamp(timestamp)

	if process == nil {
		return []interface{}{
			ts,
			gatewayID,
			agentID,
			hostID,
			uint32(0),
			"",
			float32(0),
			int64(0),
			"",
			"",
			deviceID,
			partition,
		}
	}

	return []interface{}{
		ts,
		gatewayID,
		agentID,
		hostID,
		process.PID,
		process.Name,
		process.CPUUsage,
		int64(process.MemoryUsage),
		process.Status,
		process.StartTime,
		deviceID,
		partition,
	}
}

func sanitizeTimestamp(ts time.Time) time.Time {
	if ts.IsZero() {
		return nowUTC()
	}

	return ts.UTC()
}

func normalizeJSON(raw string) (interface{}, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}

	var tmp json.RawMessage
	if err := json.Unmarshal([]byte(raw), &tmp); err != nil {
		return nil, err
	}

	return json.RawMessage(raw), nil
}
