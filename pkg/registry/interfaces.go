package registry

//go:generate mockgen -destination=mock_registry.go -package=registry github.com/carverauto/serviceradar/pkg/registry Manager

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Manager is the interface for the new authoritative Device Registry.
// It processes all device "sightings" (as DeviceUpdates) and ensures they are
// correctly identified, correlated, and persisted.
type Manager interface {
	// ProcessDeviceUpdate is the single entry point for all new device information.
	// It takes a "sighting" (in the form of a DeviceUpdate), performs
	// correlation and enrichment, and publishes the authoritative result to the database.
	ProcessDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error

	// ProcessBatchDeviceUpdates handles a batch of sightings for efficiency.
	ProcessBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error

	// GetDevice retrieves a unified device by its device ID.
	GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)

	// GetDevicesByIP retrieves all unified devices that have the given IP.
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error)

	// ListDevices retrieves a paginated list of unified devices.
	ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)

	// GetMergedDevice retrieves a device by device ID or IP, returning the merged/unified view.
	GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error)

	// FindRelatedDevices finds all devices that are related to the given device ID.
	FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error)

	// --- Legacy compatibility methods for transition period ---

	// ProcessBatchSweepResults converts legacy SweepResult sightings into the new
	// DeviceUpdate format before processing. This should be phased out.
	ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error
}
