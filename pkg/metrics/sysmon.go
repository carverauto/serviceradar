package metrics

import (
	"context"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (m *Manager) StoreSysmonMetrics(ctx context.Context, pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error {
	dbMetrics := &models.SysmonMetrics{
		CPUs:   make([]models.CPUMetric, len(metrics.CPUs)),
		Disks:  make([]models.DiskMetric, len(metrics.Disks)),
		Memory: models.MemoryMetric{},
	}

	for i, cpu := range metrics.CPUs {
		dbMetrics.CPUs[i] = models.CPUMetric{
			CoreID:       cpu.CoreID,
			UsagePercent: cpu.UsagePercent,
			Timestamp:    timestamp,
		}
	}

	for i, disk := range metrics.Disks {
		dbMetrics.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  timestamp,
		}
	}

	dbMetrics.Memory = models.MemoryMetric{
		UsedBytes:  metrics.Memory.UsedBytes,
		TotalBytes: metrics.Memory.TotalBytes,
		Timestamp:  timestamp,
	}

	if err := m.db.StoreSysmonMetrics(ctx, pollerID, dbMetrics, timestamp); err != nil {
		log.Printf("Failed to store sysmon metrics for poller %s: %v", pollerID, err)
		return err
	}

	return nil
}

func (m *Manager) GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	dbMetrics, err := m.db.GetCPUMetrics(ctx, pollerID, coreID, start, end)
	if err != nil {
		return nil, err
	}

	metrics := make([]models.CPUMetric, len(dbMetrics))
	for i, dm := range dbMetrics {
		metrics[i] = models.CPUMetric{
			CoreID:       dm.CoreID,
			UsagePercent: dm.UsagePercent,
			Timestamp:    dm.Timestamp,
		}
	}

	return metrics, nil
}

func (m *Manager) GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
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
		}
	}

	return metrics, nil
}

// GetAllDiskMetrics retrieves disk metrics for all mount points for a given poller.
func (m *Manager) GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	// Use the DB service's GetAllDiskMetrics method
	dbMetrics, err := m.db.GetAllDiskMetrics(ctx, pollerID, start, end)
	if err != nil {
		log.Printf("Error getting all disk metrics from database: %v", err)
		return nil, err
	}

	if len(dbMetrics) == 0 {
		log.Printf("No disk metrics found for poller %s", pollerID)
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
		}
	}

	return metrics, nil
}

func (m *Manager) GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
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
		}
	}

	return metrics, nil
}

// GetAllCPUMetrics retrieves all CPU metrics for a poller.
func (m *Manager) GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error) {
	return m.db.GetAllCPUMetrics(ctx, pollerID, start, end)
}

// GetAllDiskMetricsGrouped retrieves all disk metrics for a poller, grouped by timestamp.
func (m *Manager) GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error) {
	return m.db.GetAllDiskMetricsGrouped(ctx, pollerID, start, end)
}

// GetMemoryMetricsGrouped retrieves all memory metrics for a poller, grouped by timestamp.
func (m *Manager) GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error) {
	return m.db.GetMemoryMetricsGrouped(ctx, pollerID, start, end)
}
