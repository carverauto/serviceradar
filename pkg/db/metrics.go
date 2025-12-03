package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	rperfBitsPerSecondDivisor = 1e6
)

// convertValueToFloat64 converts a string value to float64, logging errors but not failing the operation.
func convertValueToFloat64(value, _ string) float64 {
	if value == "" {
		return 0.0
	}

	floatVal, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0.0
	}

	return floatVal
}

// rperfWrapper defines the outer structure received from the agent for rperf checks.
type rperfWrapper struct {
	Status       string `json:"status"`
	ResponseTime int64  `json:"response_time"`
	Available    bool   `json:"available"`
}

// queryTimeseriesMetrics executes a query on timeseries_metrics and returns the results.
func (db *DB) queryTimeseriesMetrics(
	ctx context.Context,
	pollerID, filterValue, filterColumn string,
	start, end time.Time,
) ([]models.TimeseriesMetric, error) {
	return db.cnpgQueryTimeseriesMetrics(ctx, pollerID, filterValue, filterColumn, start, end)
}

// StoreRperfMetrics stores rperf-checker data as timeseries metrics.
func (db *DB) StoreRperfMetrics(ctx context.Context, pollerID, _, message string, timestamp time.Time) error {
	var wrapper rperfWrapper

	if err := json.Unmarshal([]byte(message), &wrapper); err != nil {
		db.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Failed to unmarshal outer rperf wrapper")
		return fmt.Errorf("failed to unmarshal rperf wrapper message: %w", err)
	}

	if wrapper.Status == "" {
		db.logger.Warn().Str("poller_id", pollerID).Msg("No nested status found in rperf message")
		return nil
	}

	var rperfData struct {
		Results   []models.RperfMetric `json:"results"`
		Timestamp string               `json:"timestamp"`
	}

	if err := json.Unmarshal([]byte(wrapper.Status), &rperfData); err != nil {
		db.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Failed to unmarshal nested rperf data")
		return fmt.Errorf("failed to unmarshal nested rperf data: %w", err)
	}

	if len(rperfData.Results) == 0 {
		db.logger.Warn().Str("poller_id", pollerID).Msg("No rperf results found")
		return nil
	}

	storedCount, err := db.storeRperfMetrics(ctx, pollerID, rperfData.Results, timestamp)
	if err != nil {
		return fmt.Errorf("failed to store rperf metrics: %w", err)
	}

	db.logger.Info().Int("stored_count", storedCount).Str("poller_id", pollerID).Msg("Stored rperf metrics")

	return nil
}

// StoreRperfMetricsBatch stores multiple rperf metrics in a single batch operation.
func (db *DB) StoreRperfMetricsBatch(
	ctx context.Context, pollerID string, metrics []*models.RperfMetric, timestamp time.Time) error {
	if len(metrics) == 0 {
		db.logger.Debug().Str("poller_id", pollerID).Msg("No rperf metrics to store")
		return nil
	}

	rperfMetrics := make([]models.RperfMetric, len(metrics))
	for i, m := range metrics {
		rperfMetrics[i] = *m
	}

	storedCount, err := db.storeRperfMetrics(ctx, pollerID, rperfMetrics, timestamp)
	if err != nil {
		return fmt.Errorf("failed to store rperf metrics: %w", err)
	}

	if storedCount == 0 {
		db.logger.Debug().Str("poller_id", pollerID).Msg("No valid rperf metrics to send")
		return nil
	}

	db.logger.Info().Int("stored_count", storedCount).Str("poller_id", pollerID).Msg("Stored rperf metrics batch")

	return nil
}

func (db *DB) storeRperfMetrics(
	ctx context.Context,
	pollerID string,
	metrics []models.RperfMetric,
	timestamp time.Time,
) (int, error) {
	if len(metrics) == 0 {
		return 0, nil
	}

	series := make([]*models.TimeseriesMetric, 0, len(metrics)*3)

	for i := 0; i < len(metrics); i++ {
		result := metrics[i]
		if !result.Success {
			if result.Error != nil {
				db.logger.Warn().
					Str("target", result.Target).
					Str("poller_id", pollerID).
					Str("error", *result.Error).
					Msg("Skipping metrics storage for failed rperf test")
			}
			continue
		}

		metadataBytes, err := json.Marshal(result)
		if err != nil {
			db.logger.Error().Err(err).
				Str("poller_id", pollerID).
				Str("target", result.Target).
				Msg("Failed to marshal rperf result metadata")
			continue
		}

		metadataStr := string(metadataBytes)

		series = append(series,
			buildRperfMetric(timestamp, result.Target, "bandwidth_mbps", fmt.Sprintf("%.2f", result.BitsPerSec/rperfBitsPerSecondDivisor), metadataStr),
			buildRperfMetric(timestamp, result.Target, "jitter_ms", fmt.Sprintf("%.2f", result.JitterMs), metadataStr),
			buildRperfMetric(timestamp, result.Target, "loss_percent", fmt.Sprintf("%.1f", result.LossPercent), metadataStr),
		)
	}

	if len(series) == 0 {
		return 0, nil
	}

	if err := db.cnpgInsertTimeseriesMetrics(ctx, pollerID, series); err != nil {
		return 0, err
	}

	return len(series), nil
}

func buildRperfMetric(ts time.Time, target, suffix, value, metadata string) *models.TimeseriesMetric {
	return &models.TimeseriesMetric{
		Name:           fmt.Sprintf("rperf_%s_%s", target, suffix),
		Type:           "rperf",
		Value:          value,
		Timestamp:      ts,
		TargetDeviceIP: target,
		Metadata:       metadata,
	}
}

// StoreMetric stores a single timeseries metric using the CNPG helper.
func (db *DB) StoreMetric(ctx context.Context, pollerID string, metric *models.TimeseriesMetric) error {
	if metric == nil {
		return nil
	}

	return db.StoreMetrics(ctx, pollerID, []*models.TimeseriesMetric{metric})
}

// StoreMetrics stores multiple timeseries metrics via CNPG.
func (db *DB) StoreMetrics(ctx context.Context, pollerID string, metrics []*models.TimeseriesMetric) error {
	if len(metrics) == 0 {
		return nil
	}

	return db.cnpgInsertTimeseriesMetrics(ctx, pollerID, metrics)
}

// StoreSysmonMetrics stores sysmon metrics for CPU, disk, and memory.
func (db *DB) StoreSysmonMetrics(
	ctx context.Context,
	pollerID, agentID, hostID, partition, hostIP, deviceID string,
	sysmon *models.SysmonMetrics,
	timestamp time.Time,
) error {
	if sysmon == nil {
		return nil
	}

	if !db.useCNPGWrites() {
		db.logger.Warn().Str("poller_id", pollerID).Msg("CNPG writes disabled; skipping sysmon metrics")
		return nil
	}

	if deviceID == "" {
		deviceID = fmt.Sprintf("%s:%s", partition, hostIP)
	}

	db.logger.Info().
		Str("poller_id", pollerID).
		Str("device_id", deviceID).
		Int("cpu_count", len(sysmon.CPUs)).
		Int("cluster_count", len(sysmon.Clusters)).
		Int("disk_count", len(sysmon.Disks)).
		Int("process_count", len(sysmon.Processes)).
		Bool("has_memory", sysmon.Memory != nil).
		Msg("Storing sysmon metrics")

	if err := db.cnpgInsertCPUMetrics(ctx, pollerID, agentID, hostID, deviceID, partition, sysmon.CPUs, timestamp); err != nil {
		return fmt.Errorf("failed to store CPU metrics: %w", err)
	}

	if err := db.cnpgInsertCPUClusterMetrics(ctx, pollerID, agentID, hostID, deviceID, partition, sysmon.Clusters, timestamp); err != nil {
		return fmt.Errorf("failed to store CPU cluster metrics: %w", err)
	}

	if err := db.cnpgInsertDiskMetrics(ctx, pollerID, agentID, hostID, deviceID, partition, sysmon.Disks, timestamp); err != nil {
		return fmt.Errorf("failed to store disk metrics: %w", err)
	}

	if err := db.cnpgInsertMemoryMetrics(ctx, pollerID, agentID, hostID, deviceID, partition, sysmon.Memory, timestamp); err != nil {
		return fmt.Errorf("failed to store memory metrics: %w", err)
	}

	if err := db.cnpgInsertProcessMetrics(ctx, pollerID, agentID, hostID, deviceID, partition, sysmon.Processes, timestamp); err != nil {
		return fmt.Errorf("failed to store process metrics: %w", err)
	}

	return nil
}

// Metric read helpers.
func (db *DB) GetMetrics(
	ctx context.Context, pollerID, metricName string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	metrics, err := db.queryTimeseriesMetrics(ctx, pollerID, metricName, "metric_name", start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}

	return metrics, nil
}

func (db *DB) GetMetricsByType(
	ctx context.Context, pollerID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	metrics, err := db.queryTimeseriesMetrics(ctx, pollerID, metricType, "metric_type", start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}

	return metrics, nil
}

func (db *DB) GetCPUMetrics(
	ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	return db.cnpgGetCPUMetrics(ctx, pollerID, coreID, start, end)
}

func (db *DB) GetAllCPUMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error) {
	return db.cnpgGetAllCPUMetrics(ctx, pollerID, start, end)
}

func (db *DB) GetAllDiskMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	return db.cnpgGetAllDiskMetrics(ctx, pollerID, start, end)
}

func (db *DB) GetDiskMetrics(
	ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	return db.cnpgGetDiskMetrics(ctx, pollerID, mountPoint, start, end)
}

func (db *DB) GetMemoryMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	return db.cnpgGetMemoryMetrics(ctx, pollerID, start, end)
}

func (db *DB) GetAllDiskMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error) {
	return db.cnpgGetAllDiskMetricsGrouped(ctx, pollerID, start, end)
}

func (db *DB) GetMemoryMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error) {
	return db.cnpgGetMemoryMetricsGrouped(ctx, pollerID, start, end)
}

func (db *DB) GetAllProcessMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.ProcessMetric, error) {
	return db.cnpgGetAllProcessMetrics(ctx, pollerID, start, end)
}

func (db *DB) GetAllProcessMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonProcessResponse, error) {
	return db.cnpgGetAllProcessMetricsGrouped(ctx, pollerID, start, end)
}

func (db *DB) GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error) {
	return db.cnpgGetAllMountPoints(ctx, pollerID)
}

func (db *DB) GetMetricsForDevice(
	ctx context.Context, deviceID string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	filters := map[string]string{"device_id": deviceID}
	return db.cnpgGetTimeseriesMetricsByFilters(ctx, filters, start, end)
}

func (db *DB) GetMetricsForDeviceByType(
	ctx context.Context, deviceID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	filters := map[string]string{
		"device_id":   deviceID,
		"metric_type": metricType,
	}

	return db.cnpgGetTimeseriesMetricsByFilters(ctx, filters, start, end)
}

func (db *DB) GetICMPMetricsForDevice(
	ctx context.Context, deviceID, deviceIP string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	return db.cnpgGetICMPMetricsForDevice(ctx, deviceID, deviceIP, start, end)
}

func (db *DB) GetMetricsForPartition(
	ctx context.Context, partition string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	filters := map[string]string{"partition": partition}
	return db.cnpgGetTimeseriesMetricsByFilters(ctx, filters, start, end)
}

func (db *DB) GetDeviceMetricTypes(
	ctx context.Context, deviceIDs []string, since time.Time,
) (map[string][]string, error) {
	return db.cnpgGetDeviceMetricTypes(ctx, deviceIDs, since)
}

func (db *DB) GetDevicesWithRecentSNMPMetrics(
	ctx context.Context, deviceIDs []string,
) (map[string]bool, error) {
	return db.cnpgGetDevicesWithRecentSNMPMetrics(ctx, deviceIDs)
}
