package db

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultTimeseriesLimit             = 2000
	deviceMetricsAvailabilityChunkSize = 200
)

const cnpgTimeseriesSelect = `
SELECT
	metric_name,
	metric_type,
	value,
	metadata,
	timestamp,
	target_device_ip,
	if_index,
	device_id,
	partition,
	poller_id
FROM timeseries_metrics`

var allowedTimeseriesColumns = map[string]struct{}{
	"poller_id":   {},
	"metric_name": {},
	"metric_type": {},
	"device_id":   {},
	"partition":   {},
}

func (db *DB) cnpgQueryTimeseriesMetrics(
	ctx context.Context,
	pollerID, filterValue, filterColumn string,
	start, end time.Time,
) ([]models.TimeseriesMetric, error) {
	column, err := sanitizeTimeseriesColumn(filterColumn)
	if err != nil {
		return nil, err
	}

	query := cnpgTimeseriesSelect + fmt.Sprintf(`
WHERE poller_id = $1
  AND %s = $2
  AND timestamp BETWEEN $3 AND $4`, column)

	rows, err := db.pgPool.Query(ctx, query, pollerID, filterValue, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg timeseries metrics: %w", err)
	}
	defer rows.Close()

	return gatherCNPGTimeseriesMetrics(rows)
}

func (db *DB) cnpgGetTimeseriesMetricsByFilters(
	ctx context.Context,
	filters map[string]string,
	start, end time.Time,
) ([]models.TimeseriesMetric, error) {
	where, args, err := buildTimeseriesFilterClause(filters, start, end)
	if err != nil {
		return nil, err
	}

	query := cnpgTimeseriesSelect + `
WHERE ` + where + `
ORDER BY timestamp DESC`

	rows, err := db.pgPool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("cnpg timeseries metrics by filter: %w", err)
	}
	defer rows.Close()

	return gatherCNPGTimeseriesMetrics(rows)
}

func (db *DB) cnpgGetICMPMetricsForDevice(
	ctx context.Context,
	deviceID, deviceIP string,
	start, end time.Time,
) ([]models.TimeseriesMetric, error) {
	query := cnpgTimeseriesSelect + `
WHERE metric_type = 'icmp'
  AND timestamp BETWEEN $1 AND $2
  AND (
        device_id = $3
     OR metadata->>'device_id' = $3
     OR ($4 <> '' AND target_device_ip = $4)
     OR ($4 <> '' AND metadata->>'collector_ip' = $4)
      )
ORDER BY timestamp DESC
LIMIT $5`

	rows, err := db.pgPool.Query(ctx, query, start.UTC(), end.UTC(), deviceID, deviceIP, defaultTimeseriesLimit)
	if err != nil {
		return nil, fmt.Errorf("cnpg icmp metrics for device %s: %w", deviceID, err)
	}
	defer rows.Close()

	return gatherCNPGTimeseriesMetrics(rows)
}

func (db *DB) cnpgGetDeviceMetricTypes(
	ctx context.Context,
	deviceIDs []string,
	since time.Time,
) (map[string][]string, error) {
	result := make(map[string][]string, len(deviceIDs))
	if len(deviceIDs) == 0 {
		return result, nil
	}

	windowStart := since.UTC()

	for startIdx := 0; startIdx < len(deviceIDs); startIdx += deviceMetricsAvailabilityChunkSize {
		endIdx := startIdx + deviceMetricsAvailabilityChunkSize
		if endIdx > len(deviceIDs) {
			endIdx = len(deviceIDs)
		}

		chunk := deviceIDs[startIdx:endIdx]

		rows, err := db.pgPool.Query(ctx, `
			SELECT device_id, ARRAY_AGG(DISTINCT metric_type) AS metric_types
			FROM timeseries_metrics
			WHERE device_id = ANY($1)
			  AND timestamp >= $2
			GROUP BY device_id`,
			chunk, windowStart)
		if err != nil {
			return nil, fmt.Errorf("cnpg device metric availability: %w", err)
		}

		for rows.Next() {
			var (
				deviceID    string
				metricTypes []string
			)

			if err := rows.Scan(&deviceID, &metricTypes); err != nil {
				rows.Close()
				return nil, fmt.Errorf("cnpg scan device metric availability: %w", err)
			}

			result[deviceID] = metricTypes
		}

		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, fmt.Errorf("cnpg iterate device metric availability: %w", err)
		}

		rows.Close()
	}

	return result, nil
}

func (db *DB) cnpgGetCPUMetrics(
	ctx context.Context,
	pollerID string,
	coreID int,
	start, end time.Time,
) ([]models.CPUMetric, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, agent_id, host_id, core_id, usage_percent, frequency_hz, label, cluster
		FROM cpu_metrics
		WHERE poller_id = $1 AND core_id = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, coreID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg cpu metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.CPUMetric

	for rows.Next() {
		var (
			metric  models.CPUMetric
			agentID sql.NullString
			hostID  sql.NullString
			label   sql.NullString
			cluster sql.NullString
		)

		if err := rows.Scan(
			&metric.Timestamp,
			&agentID,
			&hostID,
			&metric.CoreID,
			&metric.UsagePercent,
			&metric.FrequencyHz,
			&label,
			&cluster,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan cpu metric: %w", err)
		}

		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metric.Label = stringFromNull(label)
		metric.Cluster = stringFromNull(cluster)
		metrics = append(metrics, metric)
	}

	return metrics, rows.Err()
}

func (db *DB) cnpgGetAllCPUMetrics(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.SysmonCPUResponse, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, agent_id, host_id, core_id, usage_percent, frequency_hz, label, cluster
		FROM cpu_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, core_id ASC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg all cpu metrics: %w", err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.CPUMetric)
	clustersByTimestamp := make(map[time.Time][]models.CPUClusterMetric)

	for rows.Next() {
		var (
			metric    models.CPUMetric
			agentID   sql.NullString
			hostID    sql.NullString
			label     sql.NullString
			cluster   sql.NullString
			timestamp time.Time
		)

		if err := rows.Scan(
			&timestamp,
			&agentID,
			&hostID,
			&metric.CoreID,
			&metric.UsagePercent,
			&metric.FrequencyHz,
			&label,
			&cluster,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan cpu metric: %w", err)
		}

		metric.Timestamp = timestamp
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metric.Label = stringFromNull(label)
		metric.Cluster = stringFromNull(cluster)

		key := timestamp.Truncate(time.Second)
		data[key] = append(data[key], metric)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	clusterRows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, agent_id, host_id, cluster, frequency_hz
		FROM cpu_cluster_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, cluster ASC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg cpu cluster metrics: %w", err)
	}
	defer clusterRows.Close()

	for clusterRows.Next() {
		var (
			clusterMetric models.CPUClusterMetric
			timestamp     time.Time
		)

		if err := clusterRows.Scan(
			&timestamp,
			&clusterMetric.AgentID,
			&clusterMetric.HostID,
			&clusterMetric.Name,
			&clusterMetric.FrequencyHz,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan cpu cluster metric: %w", err)
		}

		clusterMetric.Timestamp = timestamp
		key := timestamp.Truncate(time.Second)
		clustersByTimestamp[key] = append(clustersByTimestamp[key], clusterMetric)
	}

	if err := clusterRows.Err(); err != nil {
		return nil, err
	}

	result := make([]models.SysmonCPUResponse, 0, len(data))
	for ts, cpus := range data {
		result = append(result, models.SysmonCPUResponse{
			Cpus:      cpus,
			Clusters:  clustersByTimestamp[ts],
			Timestamp: cpus[0].Timestamp,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

func (db *DB) cnpgGetAllDiskMetrics(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.DiskMetric, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT mount_point, used_bytes, total_bytes, timestamp, agent_id, host_id
		FROM disk_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg all disk metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.DiskMetric

	for rows.Next() {
		var (
			metric  models.DiskMetric
			used    sql.NullInt64
			total   sql.NullInt64
			agentID sql.NullString
			hostID  sql.NullString
		)

		if err := rows.Scan(
			&metric.MountPoint,
			&used,
			&total,
			&metric.Timestamp,
			&agentID,
			&hostID,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan disk metric: %w", err)
		}

		metric.UsedBytes = uintFromNullInt64(used)
		metric.TotalBytes = uintFromNullInt64(total)
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metrics = append(metrics, metric)
	}

	return metrics, rows.Err()
}

func (db *DB) cnpgGetDiskMetrics(
	ctx context.Context,
	pollerID, mountPoint string,
	start, end time.Time,
) ([]models.DiskMetric, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes, agent_id, host_id
		FROM disk_metrics
		WHERE poller_id = $1 AND mount_point = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, mountPoint, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg disk metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.DiskMetric

	for rows.Next() {
		var (
			metric  models.DiskMetric
			used    sql.NullInt64
			total   sql.NullInt64
			agentID sql.NullString
			hostID  sql.NullString
		)

		if err := rows.Scan(
			&metric.Timestamp,
			&metric.MountPoint,
			&used,
			&total,
			&agentID,
			&hostID,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan disk metric: %w", err)
		}

		metric.UsedBytes = uintFromNullInt64(used)
		metric.TotalBytes = uintFromNullInt64(total)
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metrics = append(metrics, metric)
	}

	return metrics, rows.Err()
}

func (db *DB) cnpgGetMemoryMetrics(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.MemoryMetric, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes, agent_id, host_id
		FROM memory_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg memory metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.MemoryMetric

	for rows.Next() {
		var (
			metric  models.MemoryMetric
			used    sql.NullInt64
			total   sql.NullInt64
			agentID sql.NullString
			hostID  sql.NullString
		)

		if err := rows.Scan(
			&metric.Timestamp,
			&used,
			&total,
			&agentID,
			&hostID,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan memory metric: %w", err)
		}

		metric.UsedBytes = uintFromNullInt64(used)
		metric.TotalBytes = uintFromNullInt64(total)
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metrics = append(metrics, metric)
	}

	return metrics, rows.Err()
}

func (db *DB) cnpgGetAllDiskMetricsGrouped(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.SysmonDiskResponse, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes, agent_id, host_id
		FROM disk_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg grouped disk metrics: %w", err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.DiskMetric)

	for rows.Next() {
		var (
			timestamp time.Time
			metric    models.DiskMetric
			used      sql.NullInt64
			total     sql.NullInt64
			agentID   sql.NullString
			hostID    sql.NullString
		)

		if err := rows.Scan(
			&timestamp,
			&metric.MountPoint,
			&used,
			&total,
			&agentID,
			&hostID,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan grouped disk metric: %w", err)
		}

		metric.Timestamp = timestamp
		metric.UsedBytes = uintFromNullInt64(used)
		metric.TotalBytes = uintFromNullInt64(total)
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)

		data[timestamp] = append(data[timestamp], metric)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	result := make([]models.SysmonDiskResponse, 0, len(data))
	for ts, disks := range data {
		result = append(result, models.SysmonDiskResponse{
			Disks:     disks,
			Timestamp: ts,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

func (db *DB) cnpgGetMemoryMetricsGrouped(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.SysmonMemoryResponse, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes, agent_id, host_id
		FROM memory_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg grouped memory metrics: %w", err)
	}
	defer rows.Close()

	var result []models.SysmonMemoryResponse

	for rows.Next() {
		var (
			timestamp time.Time
			metric    models.MemoryMetric
			used      sql.NullInt64
			total     sql.NullInt64
			agentID   sql.NullString
			hostID    sql.NullString
		)

		if err := rows.Scan(
			&timestamp,
			&used,
			&total,
			&agentID,
			&hostID,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan grouped memory metric: %w", err)
		}

		metric.Timestamp = timestamp
		metric.UsedBytes = uintFromNullInt64(used)
		metric.TotalBytes = uintFromNullInt64(total)
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)

		result = append(result, models.SysmonMemoryResponse{
			Memory:    metric,
			Timestamp: timestamp,
		})
	}

	return result, rows.Err()
}

func (db *DB) cnpgGetAllProcessMetrics(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.ProcessMetric, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, agent_id, host_id, pid, name, cpu_usage, memory_usage, status, start_time
		FROM process_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, pid ASC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg process metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.ProcessMetric

	for rows.Next() {
		var (
			metric  models.ProcessMetric
			agentID sql.NullString
			hostID  sql.NullString
			memory  sql.NullInt64
		)

		if err := rows.Scan(
			&metric.Timestamp,
			&agentID,
			&hostID,
			&metric.PID,
			&metric.Name,
			&metric.CPUUsage,
			&memory,
			&metric.Status,
			&metric.StartTime,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan process metric: %w", err)
		}

		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metric.MemoryUsage = uintFromNullInt64(memory)
		metrics = append(metrics, metric)
	}

	return metrics, rows.Err()
}

func (db *DB) cnpgGetAllProcessMetricsGrouped(
	ctx context.Context,
	pollerID string,
	start, end time.Time,
) ([]models.SysmonProcessResponse, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT timestamp, agent_id, host_id, pid, name, cpu_usage, memory_usage, status, start_time
		FROM process_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, pid ASC`,
		pollerID, start.UTC(), end.UTC())
	if err != nil {
		return nil, fmt.Errorf("cnpg grouped process metrics: %w", err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.ProcessMetric)

	for rows.Next() {
		var (
			timestamp time.Time
			metric    models.ProcessMetric
			agentID   sql.NullString
			hostID    sql.NullString
			memory    sql.NullInt64
		)

		if err := rows.Scan(
			&timestamp,
			&agentID,
			&hostID,
			&metric.PID,
			&metric.Name,
			&metric.CPUUsage,
			&memory,
			&metric.Status,
			&metric.StartTime,
		); err != nil {
			return nil, fmt.Errorf("cnpg scan grouped process metric: %w", err)
		}

		metric.Timestamp = timestamp
		metric.AgentID = stringFromNull(agentID)
		metric.HostID = stringFromNull(hostID)
		metric.MemoryUsage = uintFromNullInt64(memory)

		data[timestamp] = append(data[timestamp], metric)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	result := make([]models.SysmonProcessResponse, 0, len(data))
	for ts, processes := range data {
		result = append(result, models.SysmonProcessResponse{
			Processes: processes,
			Timestamp: ts,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

func (db *DB) cnpgGetAllMountPoints(ctx context.Context, pollerID string) ([]string, error) {
	rows, err := db.pgPool.Query(ctx, `
		SELECT DISTINCT mount_point
		FROM disk_metrics
		WHERE poller_id = $1
		ORDER BY mount_point`, pollerID)
	if err != nil {
		return nil, fmt.Errorf("cnpg mount points: %w", err)
	}
	defer rows.Close()

	var mountPoints []string

	for rows.Next() {
		var mountPoint string
		if err := rows.Scan(&mountPoint); err != nil {
			return nil, fmt.Errorf("cnpg scan mount point: %w", err)
		}
		mountPoints = append(mountPoints, mountPoint)
	}

	return mountPoints, rows.Err()
}

func (db *DB) cnpgGetDevicesWithRecentSNMPMetrics(
	ctx context.Context,
	deviceIDs []string,
) (map[string]bool, error) {
	found := make(map[string]bool, len(deviceIDs))
	if len(deviceIDs) == 0 {
		return found, nil
	}

	cutoff := time.Now().Add(-15 * time.Minute).UTC()

	rows, err := db.pgPool.Query(ctx, `
		SELECT DISTINCT device_id
		FROM timeseries_metrics
		WHERE metric_type = 'snmp'
		  AND device_id = ANY($1)
		  AND timestamp > $2`,
		deviceIDs, cutoff)
	if err != nil {
		return nil, fmt.Errorf("cnpg recent snmp metrics: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var deviceID string
		if err := rows.Scan(&deviceID); err != nil {
			return nil, fmt.Errorf("cnpg scan snmp device: %w", err)
		}
		found[deviceID] = true
	}

	return found, rows.Err()
}

func sanitizeTimeseriesColumn(column string) (string, error) {
	if column == "" {
		return "", fmt.Errorf("timeseries column is required")
	}

	if _, ok := allowedTimeseriesColumns[column]; !ok {
		return "", fmt.Errorf("unsupported timeseries column: %s", column)
	}

	return column, nil
}

func buildTimeseriesFilterClause(
	filters map[string]string,
	start, end time.Time,
) (string, []interface{}, error) {
	if len(filters) == 0 {
		return "timestamp BETWEEN $1 AND $2", []interface{}{start.UTC(), end.UTC()}, nil
	}

	keys := make([]string, 0, len(filters))
	for key := range filters {
		if _, ok := allowedTimeseriesColumns[key]; !ok {
			return "", nil, fmt.Errorf("unsupported timeseries column: %s", key)
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)

	conditions := []string{"timestamp BETWEEN $1 AND $2"}
	args := []interface{}{start.UTC(), end.UTC()}
	argIdx := 3

	for _, key := range keys {
		conditions = append(conditions, fmt.Sprintf("%s = $%d", key, argIdx))
		args = append(args, filters[key])
		argIdx++
	}

	return strings.Join(conditions, " AND "), args, nil
}

func gatherCNPGTimeseriesMetrics(rows pgx.Rows) ([]models.TimeseriesMetric, error) {
	var metrics []models.TimeseriesMetric

	for rows.Next() {
		metric, err := scanCNPGTimeseriesMetric(rows)
		if err != nil {
			return nil, err
		}
		metrics = append(metrics, *metric)
	}

	return metrics, rows.Err()
}

func scanCNPGTimeseriesMetric(row pgx.Row) (*models.TimeseriesMetric, error) {
	var (
		metric    models.TimeseriesMetric
		value     float64
		metadata  []byte
		targetIP  sql.NullString
		ifIndex   sql.NullInt32
		deviceID  sql.NullString
		partition sql.NullString
		pollerID  sql.NullString
	)

	if err := row.Scan(
		&metric.Name,
		&metric.Type,
		&value,
		&metadata,
		&metric.Timestamp,
		&targetIP,
		&ifIndex,
		&deviceID,
		&partition,
		&pollerID,
	); err != nil {
		return nil, fmt.Errorf("cnpg scan timeseries metric: %w", err)
	}

	metric.Value = formatTimeseriesValue(value)
	metric.TargetDeviceIP = stringFromNull(targetIP)
	if ifIndex.Valid {
		metric.IfIndex = ifIndex.Int32
	}
	metric.DeviceID = stringFromNull(deviceID)
	metric.Partition = stringFromNull(partition)
	metric.PollerID = stringFromNull(pollerID)
	if len(metadata) > 0 {
		metric.Metadata = string(metadata)
	}

	return &metric, nil
}

func stringFromNull(ns sql.NullString) string {
	if ns.Valid {
		return ns.String
	}
	return ""
}

func uintFromNullInt64(n sql.NullInt64) uint64 {
	if !n.Valid {
		return 0
	}
	if n.Int64 < 0 {
		return 0
	}
	return uint64(n.Int64)
}

func formatTimeseriesValue(value float64) string {
	return strconv.FormatFloat(value, 'g', -1, 64)
}
