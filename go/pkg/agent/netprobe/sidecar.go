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
	dpiEvents     chan *netprobepb.DpiEvent
	flowEvents    chan *netprobepb.FlowAttributionEvent
	processSnaps  chan *netprobepb.ProcessSnapshot
	healthy       atomic.Bool
	unhealthy     atomic.Bool
	runningAsRoot atomic.Bool
	engineVersion atomic.Value
	revisions     atomic.Value
	lastError     atomic.Value
}

var _ sidecar.Sidecar = (*Sidecar)(nil)

type CorpusRevisions struct {
	P0f                   string `json:"p0f,omitempty"`
	ServiceRadarAdditions string `json:"serviceradar_additions,omitempty"`
	JA4                   string `json:"ja4,omitempty"`
	MuonFP                string `json:"muonfp,omitempty"`
	Recog                 string `json:"recog,omitempty"`
	Satori                string `json:"satori,omitempty"`
	ServiceRadarRecogAdds string `json:"serviceradar_recog_additions,omitempty"`
	RecogCorpusLoaded     bool   `json:"recog_corpus_loaded,omitempty"`
}

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
		cfg:          cfg,
		events:       make(chan *netprobepb.FingerprintEvent, defaultSidecarEventBuffer),
		dpiEvents:    make(chan *netprobepb.DpiEvent, defaultSidecarEventBuffer),
		flowEvents:   make(chan *netprobepb.FlowAttributionEvent, defaultSidecarEventBuffer),
		processSnaps: make(chan *netprobepb.ProcessSnapshot, defaultSidecarEventBuffer),
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
		s.revisions.Store(CorpusRevisions{
			P0f:                   netprobeClient.P0fCorpusRevision(),
			ServiceRadarAdditions: netprobeClient.ServiceRadarAdditionsRevision(),
			JA4:                   netprobeClient.JA4SpecRevision(),
			MuonFP:                netprobeClient.MuonFPCorpusRevision(),
			Recog:                 netprobeClient.RecogCorpusRevision(),
			Satori:                netprobeClient.SatoriCorpusRevision(),
			ServiceRadarRecogAdds: netprobeClient.ServiceRadarRecogAdditionsRevision(),
			RecogCorpusLoaded:     netprobeClient.RecogCorpusLoaded(),
		})
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

func (s *Sidecar) CorpusRevisions() CorpusRevisions {
	value := s.revisions.Load()
	if value == nil {
		return CorpusRevisions{}
	}
	revisions, _ := value.(CorpusRevisions)

	return revisions
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

func (s *Sidecar) MatchBanners(ctx context.Context, batch *netprobepb.BannerBatch) (*netprobepb.BannerMatchBatch, error) {
	ticker := time.NewTicker(defaultApplyWaitInterval)
	defer ticker.Stop()

	for {
		client := s.currentClient()
		if client != nil {
			return client.MatchBanners(ctx, batch)
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func (s *Sidecar) EnqueueFingerprintEvent(event *netprobepb.FingerprintEvent) {
	if event == nil {
		return
	}

	select {
	case s.events <- event:
	default:
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

func (s *Sidecar) DrainDPIEvents(max int) []*netprobepb.DpiEvent {
	if max <= 0 {
		max = defaultSidecarEventBuffer
	}

	events := make([]*netprobepb.DpiEvent, 0, max)
	for len(events) < max {
		select {
		case event := <-s.dpiEvents:
			if event != nil {
				events = append(events, event)
			}
		default:
			return events
		}
	}

	return events
}

func (s *Sidecar) DrainFlowAttributionEvents(max int) []*netprobepb.FlowAttributionEvent {
	if max <= 0 {
		max = defaultSidecarEventBuffer
	}

	events := make([]*netprobepb.FlowAttributionEvent, 0, max)
	for len(events) < max {
		select {
		case event := <-s.flowEvents:
			if event != nil {
				events = append(events, event)
			}
		default:
			return events
		}
	}

	return events
}

func (s *Sidecar) DrainProcessSnapshots(max int) []*netprobepb.ProcessSnapshot {
	if max <= 0 {
		max = defaultSidecarEventBuffer
	}

	snapshots := make([]*netprobepb.ProcessSnapshot, 0, max)
	for len(snapshots) < max {
		select {
		case snapshot := <-s.processSnaps:
			if snapshot != nil {
				snapshots = append(snapshots, snapshot)
			}
		default:
			return snapshots
		}
	}

	return snapshots
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
	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		for event := range client.Events() {
			select {
			case s.events <- event:
			default:
				// Keep the manager/IPC reader non-blocking; client-level drop metrics
				// already cover drops before this fan-in point.
			}
		}
	}()
	go func() {
		defer wg.Done()
		for event := range client.DpiEvents() {
			select {
			case s.dpiEvents <- event:
			default:
			}
		}
	}()
	go func() {
		defer wg.Done()
		for event := range client.FlowAttributionEvents() {
			select {
			case s.flowEvents <- event:
			default:
			}
		}
	}()
	go func() {
		defer wg.Done()
		for snapshot := range client.ProcessSnapshots() {
			select {
			case s.processSnaps <- snapshot:
			default:
			}
		}
	}()
	wg.Wait()

	s.mu.Lock()
	if s.client == client {
		s.client = nil
	}
	if s.eventClient == client {
		s.eventClient = nil
	}
	s.mu.Unlock()
}
