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
