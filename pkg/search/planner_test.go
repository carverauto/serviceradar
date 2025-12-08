package search

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
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
