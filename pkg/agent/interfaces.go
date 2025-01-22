package agent

import (
	"context"

	"github.com/mfreeman451/serviceradar/proto"
)

type Service interface {
	Start(context.Context) error
	Stop() error
	Name() string
}

// SweepStatusProvider is an interface for services that can provide sweep status.
type SweepStatusProvider interface {
	GetStatus(context.Context) (*proto.StatusResponse, error)
}
