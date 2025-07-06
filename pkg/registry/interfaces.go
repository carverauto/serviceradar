package registry

//go:generate mockgen -destination=mock_registry.go -package=registry github.com/carverauto/serviceradar/pkg/registry Manager

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Manager is the interface for the new authoritative Device Registry.
// It processes all device "sightings" and ensures they are correctly
// identified, correlated, and persisted.
type Manager interface {
	// ProcessSighting is the single entry point for all new device information.
	// It takes a "sighting" (in the form of a SweepResult), performs
	// correlation and enrichment, and publishes the authoritative result to the database.
	ProcessSighting(ctx context.Context, sighting *models.SweepResult) error

	// ProcessBatchSightings handles a batch of sightings for efficiency.
	ProcessBatchSightings(ctx context.Context, sightings []*models.SweepResult) error

	// Legacy compatibility methods for transition period

	ProcessSweepResult(ctx context.Context, result *models.SweepResult) error
	ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error
	UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error
	GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error)
	ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)

	// Additional methods from DeviceRegistryService interface

	GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error)
	FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error)
}
