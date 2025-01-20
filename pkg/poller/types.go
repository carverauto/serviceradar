// Package poller provides functionality for polling agent status
package poller

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

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
	cloudClient proto.PollerServiceClient
	grpcClient  *grpc.ClientConn
	mu          sync.RWMutex
	agents      map[string]*AgentConnection
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

// Check represents a service check configuration.
type Check struct {
	Type    string `json:"service_type"`
	Name    string `json:"service_name"`
	Details string `json:"details,omitempty"`
	Port    int32  `json:"port,omitempty"`
}

// AgentConfig represents configuration for a single agent.
type AgentConfig struct {
	Address string  `json:"address"`
	Checks  []Check `json:"checks"`
}

// Config represents the poller configuration.
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	CloudAddress string                 `json:"cloud_address"`
	PollInterval Duration               `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
}
