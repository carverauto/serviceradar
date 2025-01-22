// Package poller provides functionality for polling agent status
package poller

import (
	"fmt"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/checker"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/proto"
)

const (
	grpcRetries    = 3
	defaultTimeout = 30 * time.Second
)

var (
	ErrInvalidDuration      = fmt.Errorf("invalid duration")
	ErrNoConnectionForAgent = fmt.Errorf("no connection found for agent")
	ErrAgentUnhealthy       = fmt.Errorf("agent is unhealthy")
)

// AgentConnection represents a connection to an agent.
type AgentConnection struct {
	client    *grpc.ClientConn
	agentName string
}

// Poller represents the monitoring poller.
type Poller struct {
	config      Config
	registry    checker.Registry
	cloudClient proto.PollerServiceClient
	grpcClient  *grpc.ClientConn
	mu          sync.RWMutex
	agents      map[string]*AgentConnection
}

// Check represents a service check configuration.
type Check struct {
	Type    string `json:"service_type"`
	Name    string `json:"service_name"`
	Details string `json:"details,omitempty"`
	Port    int32  `json:"port,omitempty"`
}
