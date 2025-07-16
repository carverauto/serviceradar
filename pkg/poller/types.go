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
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// AgentPoller manages polling operations for a single agent.
type AgentPoller struct {
	client         proto.AgentServiceClient
	clientConn     *grpc.Client // Store grpc.Client for lifecycle management
	name           string
	config         *AgentConfig
	timeout        time.Duration
	poller         *Poller
	resultsPollers []*ResultsPoller
}

// Poller represents the monitoring poller.
type Poller struct {
	proto.UnimplementedPollerServiceServer
	config     Config
	coreClient proto.PollerServiceClient
	grpcClient *grpc.Client
	mu         sync.RWMutex
	agents     map[string]*AgentPoller // Store stateful AgentPoller instances
	done       chan struct{}
	closeOnce  sync.Once
	PollFunc   func(ctx context.Context) error // Optional override
	clock      Clock
	wg         sync.WaitGroup
	startWg    sync.WaitGroup
	logger     logger.Logger

	// Completion tracking for forwarding to sync service
	completionMu     sync.RWMutex
	agentCompletions map[string]*proto.SweepCompletionStatus // Track completion status by agent
}

// ServiceCheck manages a single service check operation.
type ServiceCheck struct {
	client    proto.AgentServiceClient
	check     Check
	pollerID  string
	agentName string
	logger    logger.Logger
}

// ResultsPoller manages GetResults polling for services that support it.
type ResultsPoller struct {
	client               proto.AgentServiceClient
	check                Check
	pollerID             string
	agentName            string
	lastResults          time.Time
	interval             time.Duration
	lastSequence         string                       // Track last sequence received from service
	lastCompletionStatus *proto.SweepCompletionStatus // Track last completion status from agent
	poller               *Poller                      // Reference to parent poller for completion aggregation
	logger               logger.Logger
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
