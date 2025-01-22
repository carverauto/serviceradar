package checker

import (
	"context"
	"fmt"
)

var (
	errNoChecker = fmt.Errorf("no checker found")
)

// Factory is a function type returning a Checker.
type Factory func(ctx context.Context, serviceName, details string) (Checker, error)

// Registry defines how to store and retrieve checker factories.
type Registry interface {
	Register(serviceType string, factory Factory)
	Get(ctx context.Context, serviceType, serviceName, details string) (Checker, error)
}

// checkerRegistry is a simple in-memory implementation of Registry.
type checkerRegistry struct {
	factories map[string]Factory
}

func NewRegistry() Registry {
	return &checkerRegistry{
		factories: make(map[string]Factory),
	}
}

func (r *checkerRegistry) Register(serviceType string, factory Factory) {
	r.factories[serviceType] = factory
}

func (r *checkerRegistry) Get(ctx context.Context, serviceType, serviceName, details string) (Checker, error) {
	f, ok := r.factories[serviceType]
	if !ok {
		return nil, fmt.Errorf("%w: %w", errNoChecker, serviceType)
	}

	return f(ctx, serviceName, details)
}
