package search

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
)

type noopRegistry struct{}

func (noopRegistry) ListDevices(context.Context, int, int) ([]*models.UnifiedDevice, error) {
	return nil, nil
}
func (noopRegistry) SearchDevices(string, int) []*models.UnifiedDevice { return nil }
func (noopRegistry) GetDevice(context.Context, string) (*models.UnifiedDevice, error) {
	return nil, nil
}
func (noopRegistry) GetCollectorCapabilities(context.Context, string) (*models.CollectorCapability, bool) {
	return nil, false
}
func (noopRegistry) HasDeviceCapability(context.Context, string, string) bool { return false }

type mockRegistry struct {
	device         *models.UnifiedDevice
	err            error
	getDeviceCalls int
}

func (m *mockRegistry) ListDevices(context.Context, int, int) ([]*models.UnifiedDevice, error) {
	return []*models.UnifiedDevice{}, nil
}
func (m *mockRegistry) SearchDevices(string, int) []*models.UnifiedDevice {
	return []*models.UnifiedDevice{}
}
func (m *mockRegistry) GetDevice(context.Context, string) (*models.UnifiedDevice, error) {
	m.getDeviceCalls++
	return m.device, m.err
}
func (m *mockRegistry) GetCollectorCapabilities(context.Context, string) (*models.CollectorCapability, bool) {
	return nil, false
}
func (m *mockRegistry) HasDeviceCapability(context.Context, string, string) bool { return false }

func TestSupportsRegistryRejectsDeviceIDFilters(t *testing.T) {
	t.Parallel()

	planner := &Planner{registry: noopRegistry{}}

	if !planner.supportsRegistry("in:devices status:online", nil) {
		t.Fatalf("expected registry to be supported for basic device query")
	}

	if planner.supportsRegistry(`in:devices device_id:"serviceradar:agent:k8s-agent"`, nil) {
		t.Fatalf("expected registry to be rejected for device_id filter")
	}
}

func TestExecuteRegistryFiltersByDeviceIDWhenSRQLUnavailable(t *testing.T) {
	t.Parallel()

	device := &models.UnifiedDevice{
		DeviceID: "serviceradar:agent:docker-agent",
	}
	reg := &mockRegistry{device: device}

	planner := &Planner{registry: reg}
	req := &Request{
		Query: `in:devices device_id:"serviceradar:agent:docker-agent" limit:1`,
		Pagination: Pagination{
			Limit:  5,
			Offset: 0,
		},
	}

	devices, pagination, err := planner.executeRegistry(context.Background(), req)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if reg.getDeviceCalls != 1 {
		t.Fatalf("expected GetDevice to be called once, got %d", reg.getDeviceCalls)
	}
	if len(devices) != 1 || devices[0].DeviceID != device.DeviceID {
		t.Fatalf("unexpected devices returned: %+v", devices)
	}
	if pagination.Limit != 5 || pagination.Offset != 0 {
		t.Fatalf("unexpected pagination: %+v", pagination)
	}
}

func TestExecuteRegistryReturnsEmptyWhenDeviceIDMissing(t *testing.T) {
	t.Parallel()

	reg := &mockRegistry{err: registry.ErrDeviceNotFound}
	planner := &Planner{registry: reg}

	req := &Request{
		Query: `in:devices device_id:"serviceradar:agent:missing" limit:1`,
		Pagination: Pagination{
			Limit:  1,
			Offset: 0,
		},
	}

	devices, pagination, err := planner.executeRegistry(context.Background(), req)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(devices) != 0 {
		t.Fatalf("expected no devices, got %+v", devices)
	}
	if pagination.Limit != 1 || pagination.Offset != 0 {
		t.Fatalf("unexpected pagination: %+v", pagination)
	}
}
