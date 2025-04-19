package metrics

import (
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (m *Manager) StoreSysmonMetrics(pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error {
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

	if err := m.db.StoreSysmonMetrics(pollerID, dbMetrics, timestamp); err != nil {
		log.Printf("Failed to store sysmon metrics for poller %s: %v", pollerID, err)

		return err
	}

	log.Printf("Stored sysmon metrics for poller %s: %d CPUs, %d disks, 1 memory",
		pollerID, len(metrics.CPUs), len(metrics.Disks))

	return nil
}

func (m *Manager) GetCPUMetrics(pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	dbMetrics, err := m.db.GetCPUMetrics(pollerID, coreID, start, end)
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

func (m *Manager) GetDiskMetrics(pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	dbMetrics, err := m.db.GetDiskMetrics(pollerID, mountPoint, start, end)
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
func (m *Manager) GetAllDiskMetrics(pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	log.Printf("Getting all disk metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	// Use the DB service's GetAllDiskMetrics method
	dbMetrics, err := m.db.GetAllDiskMetrics(pollerID, start, end)
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

	log.Printf("Retrieved %d disk metrics for poller %s", len(metrics), pollerID)

	return metrics, nil
}

func (m *Manager) GetMemoryMetrics(pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	dbMetrics, err := m.db.GetMemoryMetrics(pollerID, start, end)
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
