package registry

//go:generate mockgen -destination=mock_registry.go -package=registry github.com/carverauto/serviceradar/pkg/registry Manager
//go:generate mockgen -destination=mock_service_registry.go -package=registry github.com/carverauto/serviceradar/pkg/registry ServiceManager

import (
	"context"
	"time"

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
}

// ServiceManager manages the lifecycle and registration of all services
// (pollers, agents, checkers) in the ServiceRadar system.
type ServiceManager interface {
	// RegisterPoller explicitly registers a new poller.
	// Used during edge package creation, K8s ClusterSPIFFEID creation, etc.
	RegisterPoller(ctx context.Context, reg *PollerRegistration) error

	// RegisterAgent explicitly registers a new agent under a poller.
	RegisterAgent(ctx context.Context, reg *AgentRegistration) error

	// RegisterChecker explicitly registers a new checker under an agent.
	RegisterChecker(ctx context.Context, reg *CheckerRegistration) error

	// RecordHeartbeat records a service heartbeat from status reports.
	// This updates last_seen and activates pending services.
	RecordHeartbeat(ctx context.Context, heartbeat *ServiceHeartbeat) error

	// RecordBatchHeartbeats handles batch heartbeat updates efficiently.
	RecordBatchHeartbeats(ctx context.Context, heartbeats []*ServiceHeartbeat) error

	// GetPoller retrieves a poller by ID.
	GetPoller(ctx context.Context, pollerID string) (*RegisteredPoller, error)

	// GetAgent retrieves an agent by ID.
	GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error)

	// GetChecker retrieves a checker by ID.
	GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error)

	// ListPollers retrieves all pollers matching filter.
	ListPollers(ctx context.Context, filter *ServiceFilter) ([]*RegisteredPoller, error)

	// ListAgentsByPoller retrieves all agents under a poller.
	ListAgentsByPoller(ctx context.Context, pollerID string) ([]*RegisteredAgent, error)

	// ListCheckersByAgent retrieves all checkers under an agent.
	ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error)

	// UpdateServiceStatus updates the status of a service.
	UpdateServiceStatus(ctx context.Context, serviceType string, serviceID string, status ServiceStatus) error

	// MarkInactive marks services as inactive if they haven't reported within threshold.
	// This is typically called by a background job.
	// Returns the number of services marked inactive.
	MarkInactive(ctx context.Context, threshold time.Duration) (int, error)

	// IsKnownPoller checks if a poller is registered and active.
	// Replaces the logic currently in pkg/core/pollers.go:701
	IsKnownPoller(ctx context.Context, pollerID string) (bool, error)

	// DeleteService permanently deletes a service from the registry.
	// This should only be called for services that are no longer needed (status: revoked, inactive, or deleted).
	// Returns error if service is still active or pending.
	DeleteService(ctx context.Context, serviceType, serviceID string) error

	// PurgeInactive permanently deletes services that have been inactive, revoked, or deleted
	// for longer than the retention period. This is typically called by a background job.
	// Returns the number of services deleted.
	PurgeInactive(ctx context.Context, retentionPeriod time.Duration) (int, error)
}
