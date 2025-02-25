package agent

import (
	"context"

	"github.com/carverauto/serviceradar/proto"
)

//go:generate mockgen -destination=mock_agent.go -package=agent github.com/carverauto/serviceradar/pkg/agent Service,SweepStatusProvider

type Service interface {
	Start(context.Context) error
	Stop(ctx context.Context) error
	Name() string
}

// SweepStatusProvider is an interface for services that can provide sweep status.
type SweepStatusProvider interface {
	GetStatus(context.Context) (*proto.StatusResponse, error)
}
