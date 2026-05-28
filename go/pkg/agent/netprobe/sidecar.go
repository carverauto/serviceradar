/*
 * Copyright 2026 Carver Automation Corporation.
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

package netprobe

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const (
	DefaultSidecarName               = "netprobe"
	DefaultBinaryPath                = "/usr/local/lib/serviceradar/bin/serviceradar-netprobe"
	DefaultLogFormat                 = "json"
	defaultHealthPort         uint16 = 0
	defaultSidecarEventBuffer        = 1024
	defaultApplyWaitInterval         = 100 * time.Millisecond
)

var ErrSidecarUnavailable = errors.New("netprobe sidecar is unavailable")

// SidecarConfig configures the netprobe sidecar process.
type SidecarConfig struct {
	Name       string
	BinaryPath string
	LogFormat  string
	HealthPort uint16
	ExtraArgs  []string
}

// Sidecar implements the generic agent sidecar contract for serviceradar-netprobe.
type Sidecar struct {
	cfg SidecarConfig

	mu            sync.RWMutex
	client        *Client
	eventClient   *Client
	events        chan *netprobepb.FingerprintEvent
	healthy       atomic.Bool
	unhealthy     atomic.Bool
	runningAsRoot atomic.Bool
	engineVersion atomic.Value
	lastError     atomic.Value
}

var _ sidecar.Sidecar = (*Sidecar)(nil)

// NewSidecar creates a netprobe sidecar adapter.
func NewSidecar(cfg SidecarConfig) *Sidecar {
	if cfg.Name == "" {
		cfg.Name = DefaultSidecarName
	}
	if cfg.BinaryPath == "" {
		cfg.BinaryPath = DefaultBinaryPath
	}
	if cfg.LogFormat == "" {
		cfg.LogFormat = DefaultLogFormat
	}

	return &Sidecar{
		cfg:    cfg,
		events: make(chan *netprobepb.FingerprintEvent, defaultSidecarEventBuffer),
	}
}

// ClientFactory returns the health/client factory expected by the sidecar manager.
func ClientFactory() sidecar.ClientFactory {
	return func(ctx context.Context, socketPath string) (sidecar.Client, error) {
		return Dial(ctx, socketPath)
	}
}

func (s *Sidecar) Name() string {
	return s.cfg.Name
}

func (s *Sidecar) BinaryPath() string {
	return s.cfg.BinaryPath
}

func (s *Sidecar) Args(socketPath, configPath string) []string {
	args := []string{
		"--socket", socketPath,
		"--config", configPath,
		"--log-format", s.cfg.LogFormat,
	}
	if s.cfg.HealthPort != defaultHealthPort {
		args = append(args, "--health-port", strconv.FormatUint(uint64(s.cfg.HealthPort), 10))
	}
	args = append(args, s.cfg.ExtraArgs...)

	return args
}

func (s *Sidecar) OnHealthy(client sidecar.Client) {
	s.healthy.Store(true)
	s.unhealthy.Store(false)
	s.lastError.Store("")

	if netprobeClient, ok := client.(*Client); ok {
		s.engineVersion.Store(netprobeClient.FingerprintEngineVersion())
		s.runningAsRoot.Store(netprobeClient.RunningAsRoot())
		s.setClient(netprobeClient)
	}
}

func (s *Sidecar) OnUnhealthy(err error) {
	s.healthy.Store(false)
	s.unhealthy.Store(true)
	s.setClient(nil)
	if err != nil {
		s.lastError.Store(err.Error())
	}
}

func (s *Sidecar) Healthy() bool {
	return s.healthy.Load()
}

func (s *Sidecar) FingerprintEngineVersion() string {
	value := s.engineVersion.Load()
	if value == nil {
		return ""
	}
	version, _ := value.(string)

	return version
}

func (s *Sidecar) RunningAsRoot() bool {
	return s.runningAsRoot.Load()
}

func (s *Sidecar) ApplyConfig(ctx context.Context, cfg *netprobepb.VisibilityAgentConfig) (string, error) {
	ticker := time.NewTicker(defaultApplyWaitInterval)
	defer ticker.Stop()

	for {
		client := s.currentClient()
		if client != nil {
			return client.ApplyConfig(ctx, cfg)
		}

		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-ticker.C:
		}
	}
}

func (s *Sidecar) DrainEvents(max int) []*netprobepb.FingerprintEvent {
	if max <= 0 {
		max = defaultSidecarEventBuffer
	}

	events := make([]*netprobepb.FingerprintEvent, 0, max)
	for len(events) < max {
		select {
		case event := <-s.events:
			if event != nil {
				events = append(events, event)
			}
		default:
			return events
		}
	}

	return events
}

func (s *Sidecar) currentClient() *Client {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.client
}

func (s *Sidecar) setClient(client *Client) {
	s.mu.Lock()
	if s.client == client {
		s.mu.Unlock()
		return
	}
	s.client = client
	if client == nil {
		s.eventClient = nil
		s.mu.Unlock()
		return
	}
	if s.eventClient == client {
		s.mu.Unlock()
		return
	}
	s.eventClient = client
	s.mu.Unlock()

	go s.forwardEvents(client)
}

func (s *Sidecar) forwardEvents(client *Client) {
	for event := range client.Events() {
		select {
		case s.events <- event:
		default:
			// Keep the manager/IPC reader non-blocking; client-level drop metrics
			// already cover drops before this fan-in point.
		}
	}

	s.mu.Lock()
	if s.client == client {
		s.client = nil
	}
	if s.eventClient == client {
		s.eventClient = nil
	}
	s.mu.Unlock()
}
