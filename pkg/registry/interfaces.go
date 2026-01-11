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

	// GetDevice retrieves an OCSF device by its device ID.
	GetDevice(ctx context.Context, deviceID string) (*models.OCSFDevice, error)

	// GetDeviceByIDStrict retrieves an OCSF device by device ID only (no IP fallback).
	GetDeviceByIDStrict(ctx context.Context, deviceID string) (*models.OCSFDevice, error)

	// GetDevicesByIP retrieves all OCSF devices that have the given IP.
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.OCSFDevice, error)

	// ListDevices retrieves a paginated list of OCSF devices.
	ListDevices(ctx context.Context, limit, offset int) ([]*models.OCSFDevice, error)

	// FindRelatedDevices finds all devices that are related to the given device ID.
	FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.OCSFDevice, error)

	// SetCollectorCapabilities stores explicit collector capability information for a device.
	SetCollectorCapabilities(ctx context.Context, capability *models.CollectorCapability)

	// GetCollectorCapabilities returns the capability record for a device, if present.
	GetCollectorCapabilities(ctx context.Context, deviceID string) (*models.CollectorCapability, bool)

	// SetDeviceCapabilitySnapshot records a capability snapshot in the capability matrix.
	SetDeviceCapabilitySnapshot(ctx context.Context, snapshot *models.DeviceCapabilitySnapshot)

	// ListDeviceCapabilitySnapshots returns all capability snapshots tracked for the device.
	ListDeviceCapabilitySnapshots(ctx context.Context, deviceID string) []*models.DeviceCapabilitySnapshot

	// HasDeviceCapability reports whether a device currently exposes the provided capability.
	HasDeviceCapability(ctx context.Context, deviceID, capability string) bool

	// ListDevicesWithCapability returns the device IDs that currently expose the provided capability.
	ListDevicesWithCapability(ctx context.Context, capability string) []string

	// DeleteLocal removes a device from the local in-memory registry without emitting tombstones.
	// This is used for cleaning up stale or ephemeral devices (e.g. from sweep).
	DeleteLocal(deviceID string)

	// ReconcileSightings promotes eligible network sightings into unified devices per policy.
	ReconcileSightings(ctx context.Context) error

	// ListSightings returns active sightings for the given partition (empty for all).
	ListSightings(ctx context.Context, partition string, limit, offset int) ([]*models.NetworkSighting, error)

	// CountSightings returns the total active sightings for pagination.
	CountSightings(ctx context.Context, partition string) (int64, error)

	// PromoteSighting manually promotes a specific sighting.
	PromoteSighting(ctx context.Context, sightingID, actor string) (*models.DeviceUpdate, error)

	// DismissSighting marks a sighting dismissed and records audit.
	DismissSighting(ctx context.Context, sightingID, actor, reason string) error

	// ListSightingEvents returns audit history for a sighting.
	ListSightingEvents(ctx context.Context, sightingID string, limit int) ([]*models.SightingEvent, error)
}

// ServiceManager manages the lifecycle and registration of all services
// (gateways, agents, checkers) in the ServiceRadar system.
type ServiceManager interface {
	// RegisterGateway explicitly registers a new gateway.
	// Used during edge package creation, K8s ClusterSPIFFEID creation, etc.
	RegisterGateway(ctx context.Context, reg *GatewayRegistration) error

	// RegisterAgent explicitly registers a new agent under a gateway.
	RegisterAgent(ctx context.Context, reg *AgentRegistration) error

	// RegisterChecker explicitly registers a new checker under an agent.
	RegisterChecker(ctx context.Context, reg *CheckerRegistration) error

	// RecordHeartbeat records a service heartbeat from status reports.
	// This updates last_seen and activates pending services.
	RecordHeartbeat(ctx context.Context, heartbeat *ServiceHeartbeat) error

	// RecordBatchHeartbeats handles batch heartbeat updates efficiently.
	RecordBatchHeartbeats(ctx context.Context, heartbeats []*ServiceHeartbeat) error

	// GetGateway retrieves a gateway by ID.
	GetGateway(ctx context.Context, gatewayID string) (*RegisteredGateway, error)

	// GetAgent retrieves an agent by ID.
	GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error)

	// GetChecker retrieves a checker by ID.
	GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error)

	// ListGateways retrieves all gateways matching filter.
	ListGateways(ctx context.Context, filter *ServiceFilter) ([]*RegisteredGateway, error)

	// ListAgentsByGateway retrieves all agents under a gateway.
	ListAgentsByGateway(ctx context.Context, gatewayID string) ([]*RegisteredAgent, error)

	// ListCheckersByAgent retrieves all checkers under an agent.
	ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error)

	// UpdateServiceStatus updates the status of a service.
	UpdateServiceStatus(ctx context.Context, serviceType string, serviceID string, status ServiceStatus) error

	// MarkInactive marks services as inactive if they haven't reported within threshold.
	// This is typically called by a background job.
	// Returns the number of services marked inactive.
	MarkInactive(ctx context.Context, threshold time.Duration) (int, error)

	// IsKnownGateway checks if a gateway is registered and active.
	// Replaces the logic currently in pkg/core/gateways.go:701
	IsKnownGateway(ctx context.Context, gatewayID string) (bool, error)

	// DeleteService permanently deletes a service from the registry.
	// This should only be called for services that are no longer needed (status: revoked, inactive, or deleted).
	// Returns error if service is still active or pending.
	DeleteService(ctx context.Context, serviceType, serviceID string) error

	// PurgeInactive permanently deletes services that have been inactive, revoked, or deleted
	// for longer than the retention period. This is typically called by a background job.
	// Returns the number of services deleted.
	PurgeInactive(ctx context.Context, retentionPeriod time.Duration) (int, error)
}
