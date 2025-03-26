package poller

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/proto"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

// AgentPoller manages polling operations for a single agent.
type AgentPoller struct {
	client  proto.AgentServiceClient
	name    string
	config  *AgentConfig
	timeout time.Duration
}

// AgentConnection represents a connection to an agent.
type AgentConnection struct {
	client       *grpc.Client // Updated to use grpc.Client
	agentName    string
	healthClient healthpb.HealthClient
}

// Poller represents the monitoring poller.
type Poller struct {
	proto.UnimplementedPollerServiceServer
	config     Config
	coreClient proto.PollerServiceClient
	grpcClient *grpc.Client
	mu         sync.RWMutex
	agents     map[string]*AgentConnection
	done       chan struct{}
	closeOnce  sync.Once
	PollFunc   func(ctx context.Context) error // Optional override
	clock      Clock
	wg         sync.WaitGroup
	startWg    sync.WaitGroup
}

// ServiceCheck manages a single service check operation.
type ServiceCheck struct {
	client proto.AgentServiceClient
	check  Check
}

// Duration is a wrapper around time.Duration for JSON unmarshaling.
type Duration time.Duration

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}

		*d = Duration(tmp)
	default:
		return ErrInvalidDuration
	}

	return nil
}
