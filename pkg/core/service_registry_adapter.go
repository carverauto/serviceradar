package core

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/registry"
)

// serviceRegistryAdapter adapts the registry.ServiceManager to the edge onboarding ServiceManager interface.
// This avoids import cycles between pkg/core and pkg/registry.
type serviceRegistryAdapter struct {
	registry registry.ServiceManager
}

func newServiceRegistryAdapter(reg registry.ServiceManager) ServiceManager {
	return &serviceRegistryAdapter{registry: reg}
}

func (a *serviceRegistryAdapter) RegisterPoller(ctx context.Context, reg *PollerRegistration) error {
	return a.registry.RegisterPoller(ctx, &registry.PollerRegistration{
		PollerID:           reg.PollerID,
		ComponentID:        reg.ComponentID,
		RegistrationSource: registry.RegistrationSource(reg.RegistrationSource),
		Metadata:           reg.Metadata,
		SPIFFEIdentity:     reg.SPIFFEIdentity,
		CreatedBy:          reg.CreatedBy,
	})
}

func (a *serviceRegistryAdapter) RegisterAgent(ctx context.Context, reg *AgentRegistration) error {
	return a.registry.RegisterAgent(ctx, &registry.AgentRegistration{
		AgentID:            reg.AgentID,
		PollerID:           reg.PollerID,
		ComponentID:        reg.ComponentID,
		RegistrationSource: registry.RegistrationSource(reg.RegistrationSource),
		Metadata:           reg.Metadata,
		SPIFFEIdentity:     reg.SPIFFEIdentity,
		CreatedBy:          reg.CreatedBy,
	})
}

func (a *serviceRegistryAdapter) RegisterChecker(ctx context.Context, reg *CheckerRegistration) error {
	return a.registry.RegisterChecker(ctx, &registry.CheckerRegistration{
		CheckerID:          reg.CheckerID,
		AgentID:            reg.AgentID,
		PollerID:           reg.PollerID,
		CheckerKind:        reg.CheckerKind,
		ComponentID:        reg.ComponentID,
		RegistrationSource: registry.RegistrationSource(reg.RegistrationSource),
		Metadata:           reg.Metadata,
		SPIFFEIdentity:     reg.SPIFFEIdentity,
		CreatedBy:          reg.CreatedBy,
	})
}
