package metrics

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (m *Manager) StoreSysmonMetrics(
	ctx context.Context, pollerID, agentID, hostID, partition, hostIP string, metrics *models.SysmonMetrics, timestamp time.Time) error {
	dbMetrics := &models.SysmonMetrics{
		CPUs:      make([]models.CPUMetric, len(metrics.CPUs)),
		Clusters:  make([]models.CPUClusterMetric, len(metrics.Clusters)),
		Disks:     make([]models.DiskMetric, len(metrics.Disks)),
		Memory:    &models.MemoryMetric{},
		Processes: make([]models.ProcessMetric, len(metrics.Processes)),
	}

	for i, cpu := range metrics.CPUs {
		dbMetrics.CPUs[i] = models.CPUMetric{
			CoreID:       cpu.CoreID,
			UsagePercent: cpu.UsagePercent,
			FrequencyHz:  cpu.FrequencyHz,
			Label:        cpu.Label,
			Cluster:      cpu.Cluster,
			Timestamp:    timestamp,
			HostID:       hostID,
			HostIP:       hostIP,
			AgentID:      agentID,
		}
	}

	for i, cluster := range metrics.Clusters {
		dbMetrics.Clusters[i] = models.CPUClusterMetric{
			Name:        cluster.Name,
			FrequencyHz: cluster.FrequencyHz,
			Timestamp:   timestamp,
			HostID:      hostID,
			HostIP:      hostIP,
			AgentID:     agentID,
		}
	}

	for i, disk := range metrics.Disks {
		dbMetrics.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  timestamp,
			HostID:     hostID,
			HostIP:     hostIP,
			AgentID:    agentID,
		}
	}

	dbMetrics.Memory = &models.MemoryMetric{
		UsedBytes:  metrics.Memory.UsedBytes,
		TotalBytes: metrics.Memory.TotalBytes,
		Timestamp:  timestamp,
		HostID:     hostID,
		HostIP:     hostIP,
		AgentID:    agentID,
	}

	for i := range metrics.Processes {
		process := &metrics.Processes[i]
		dbMetrics.Processes[i] = models.ProcessMetric{
			PID:         process.PID,
			Name:        process.Name,
			CPUUsage:    process.CPUUsage,
			MemoryUsage: process.MemoryUsage,
			Status:      process.Status,
			StartTime:   process.StartTime,
			Timestamp:   timestamp,
			HostID:      hostID,
			HostIP:      hostIP,
			AgentID:     agentID,
		}
	}

	if err := m.db.StoreSysmonMetrics(ctx, pollerID, agentID, hostID, partition, hostIP, dbMetrics, timestamp); err != nil {
		m.logger.Error().Str("pollerID", pollerID).Err(err).Msg("Failed to store sysmon metrics")
		return err
	}

	return nil
}

func (m *Manager) GetCPUMetrics(
	ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	dbMetrics, err := m.db.GetCPUMetrics(ctx, pollerID, coreID, start, end)
	if err != nil {
		return nil, err
	}

	metrics := make([]models.CPUMetric, len(dbMetrics))
	for i, dm := range dbMetrics {
		metrics[i] = models.CPUMetric{
			CoreID:       dm.CoreID,
			UsagePercent: dm.UsagePercent,
			FrequencyHz:  dm.FrequencyHz,
			Timestamp:    dm.Timestamp,
			HostID:       dm.HostID,
			HostIP:       dm.HostIP,
			AgentID:      dm.AgentID,
			Label:        dm.Label,
			Cluster:      dm.Cluster,
		}
	}

	return metrics, nil
}

func (m *Manager) GetDiskMetrics(
	ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	dbMetrics, err := m.db.GetDiskMetrics(ctx, pollerID, mountPoint, start, end)
	if err != nil {
		return nil, err
	}

	metrics := make([]models.DiskMetric, len(dbMetrics))
	for i, dm := range dbMetrics {
		metrics[i] = models.DiskMetric{
			MountPoint: dm.MountPoint,
			UsedBytes:  dm.UsedBytes,
			TotalBytes: dm.TotalBytes,
			Timestamp:  dm.Timestamp,
			HostID:     dm.HostID,
			AgentID:    dm.AgentID,
		}
	}

	return metrics, nil
}

// GetAllDiskMetrics retrieves disk metrics for all mount points for a given poller.
func (m *Manager) GetAllDiskMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	// Use the DB service's GetAllDiskMetrics method
	dbMetrics, err := m.db.GetAllDiskMetrics(ctx, pollerID, start, end)
	if err != nil {
		m.logger.Error().Err(err).Msg("Error getting all disk metrics from database")
		return nil, err
	}

	if len(dbMetrics) == 0 {
		m.logger.Info().Str("pollerID", pollerID).Msg("No disk metrics found for poller")
		return []models.DiskMetric{}, nil
	}

	// Convert to models.DiskMetric (should be a no-op since the DB already returns this type)
	metrics := make([]models.DiskMetric, len(dbMetrics))
	for i, dm := range dbMetrics {
		metrics[i] = models.DiskMetric{
			MountPoint: dm.MountPoint,
			UsedBytes:  dm.UsedBytes,
			TotalBytes: dm.TotalBytes,
			Timestamp:  dm.Timestamp,
			HostID:     dm.HostID,
			AgentID:    dm.AgentID,
		}
	}

	return metrics, nil
}

func (m *Manager) GetMemoryMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	dbMetrics, err := m.db.GetMemoryMetrics(ctx, pollerID, start, end)
	if err != nil {
		return nil, err
	}

	metrics := make([]models.MemoryMetric, len(dbMetrics))
	for i, dm := range dbMetrics {
		metrics[i] = models.MemoryMetric{
			UsedBytes:  dm.UsedBytes,
			TotalBytes: dm.TotalBytes,
			Timestamp:  dm.Timestamp,
			HostID:     dm.HostID,
			AgentID:    dm.AgentID,
		}
	}

	return metrics, nil
}

// GetAllCPUMetrics retrieves all CPU metrics for a poller.
func (m *Manager) GetAllCPUMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error) {
	return m.db.GetAllCPUMetrics(ctx, pollerID, start, end)
}

// GetAllDiskMetricsGrouped retrieves all disk metrics for a poller, grouped by timestamp.
func (m *Manager) GetAllDiskMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error) {
	return m.db.GetAllDiskMetricsGrouped(ctx, pollerID, start, end)
}

// GetMemoryMetricsGrouped retrieves all memory metrics for a poller, grouped by timestamp.
func (m *Manager) GetMemoryMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error) {
	return m.db.GetMemoryMetricsGrouped(ctx, pollerID, start, end)
}

// GetAllProcessMetrics retrieves all process metrics for a poller.
func (m *Manager) GetAllProcessMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.ProcessMetric, error) {
	return m.db.GetAllProcessMetrics(ctx, pollerID, start, end)
}

// GetAllProcessMetricsGrouped retrieves all process metrics for a poller, grouped by timestamp.
func (m *Manager) GetAllProcessMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonProcessResponse, error) {
	return m.db.GetAllProcessMetricsGrouped(ctx, pollerID, start, end)
}
