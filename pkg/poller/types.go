/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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
	poller  *Poller
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
	client   proto.AgentServiceClient
	check    Check
	pollerID string
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
