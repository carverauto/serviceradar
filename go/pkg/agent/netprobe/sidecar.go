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
	"github.com/rs/zerolog"
)

const (
	DefaultSidecarName                  = "netprobe"
	DefaultBinaryPath                   = "/usr/local/lib/serviceradar/bin/serviceradar-netprobe"
	DefaultLogFormat                    = "json"
	defaultHealthPort            uint16 = 0
	defaultSidecarEventBuffer           = 1024
	defaultFlowAttributionBuffer        = 65_536
	defaultApplyWaitInterval            = 100 * time.Millisecond
	defaultDesiredApplyTimeout          = 30 * time.Second
)

var ErrSidecarUnavailable = errors.New("netprobe sidecar is unavailable")

// SidecarConfig configures the netprobe sidecar process.
type SidecarConfig struct {
	Name       string
	BinaryPath string
	LogFormat  string
	HealthPort uint16
	ExtraArgs  []string
	Logger     zerolog.Logger
}

// Sidecar implements the generic agent sidecar contract for serviceradar-netprobe.
type Sidecar struct {
	cfg    SidecarConfig
	logger zerolog.Logger

	mu                           sync.RWMutex
	client                       *Client
	eventClient                  *Client
	events                       chan *netprobepb.FingerprintEvent
	dpiEvents                    chan *netprobepb.DpiEvent
	flowEvents                   chan *netprobepb.FlowAttributionEvent
	processSnaps                 chan *netprobepb.ProcessSnapshot
	droppedFlowAttributionEvents atomic.Uint64
	healthy                      atomic.Bool
	unhealthy                    atomic.Bool
	runningAsRoot                atomic.Bool
	engineVersion                atomic.Value
	revisions                    atomic.Value
	lastError                    atomic.Value

	// addonCommands is netprobe's generic AddonService.RunCommand client, set by
	// AttachManager once it knows the socket path. nil until then, and nil forever
	// on a host whose netprobe predates the contract.
	addonCommands atomic.Pointer[AddonCommandClient]

	// desiredConfig + applyMu implement apply-on-connect: the latest desired visibility
	// config is (re)applied over IPC whenever a client connects, so a systemd-managed
	// netprobe that the agent only attaches to (does not launch) gets its full config on
	// startup AND after any restart — independent of the gateway config poll cadence.
	// applyFn is the push primitive (default: poll-for-client + Client.ApplyConfig);
	// overridable in tests to avoid a live IPC client. baseCtx (guarded by mu, supplied by
	// SetDesiredConfig from the agent run/poll-loop context) bounds the fire-and-forget
	// push: it must outlive the triggering config-apply call (so the first push can keep
	// polling for a not-yet-started netprobe), yet be cancelled on agent shutdown rather
	// than detached via context.Background(). The reconnect trigger (setClient) has no ctx
	// in scope, so the lifetime ctx is stored here rather than threaded through OnHealthy.
	desiredConfig atomic.Pointer[netprobepb.VisibilityAgentConfig]
	applyMu       sync.Mutex
	applyFn       func(context.Context, *netprobepb.VisibilityAgentConfig) (string, error)
	baseCtx       context.Context
}

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

	s := &Sidecar{
		cfg:          cfg,
		logger:       cfg.Logger,
		events:       make(chan *netprobepb.FingerprintEvent, defaultSidecarEventBuffer),
		dpiEvents:    make(chan *netprobepb.DpiEvent, defaultSidecarEventBuffer),
		flowEvents:   make(chan *netprobepb.FlowAttributionEvent, defaultFlowAttributionBuffer),
		processSnaps: make(chan *netprobepb.ProcessSnapshot, defaultSidecarEventBuffer),
		baseCtx:      context.Background(),
	}
	// Default push primitive reuses ApplyConfig (poll-for-client + Client.ApplyConfig).
	s.applyFn = s.ApplyConfig

	return s
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

// ActiveCaptureCount reports live captures on the currently attached netprobe
// connection. A disconnect reports zero because failAllCaptureSessions closes and
// removes every session before the client is detached.
func (s *Sidecar) ActiveCaptureCount() int {
	client := s.currentClient()
	if client == nil {
		return 0
	}

	return client.ActiveCaptureCount()
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

// SetDesiredConfig records the latest desired visibility config and (re)applies it over IPC.
// Used by the systemd-managed (attach) path, where the agent does not launch netprobe: the
// config is pushed asynchronously so a not-yet-running netprobe never blocks the caller, and
// it is re-pushed on every (re)connect via pushDesired (see setClient), so the full config
// (incl. device bindings, which the bootstrap file does not carry) survives systemd restarts
// regardless of the gateway config poll cadence. Pass nil to clear when the add-on assignment
// is absent. ctx is the agent run/poll-loop context; it bounds the async push to the agent
// lifetime (cancelled on shutdown).
func (s *Sidecar) SetDesiredConfig(ctx context.Context, cfg *netprobepb.VisibilityAgentConfig) {
	if ctx != nil {
		s.mu.Lock()
		s.baseCtx = ctx
		s.mu.Unlock()
	}

	s.desiredConfig.Store(cfg)
	if cfg == nil {
		return
	}

	go s.pushDesired()
}

// pushDesired applies the latest desired config to netprobe over IPC, serialized so the
// triggers (a config change and a (re)connect) cannot interleave; it always applies the
// newest stored config, so the last write wins. The per-attempt timeout derives from the
// stored agent lifetime context (set by SetDesiredConfig), so a push outlives the config-apply
// call that triggered it but is cancelled on agent shutdown.
func (s *Sidecar) pushDesired() {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()

	cfg := s.desiredConfig.Load()
	if cfg == nil {
		return
	}

	s.mu.RLock()
	base := s.baseCtx
	s.mu.RUnlock()
	if base == nil {
		base = context.Background()
	}

	ctx, cancel := context.WithTimeout(base, defaultDesiredApplyTimeout)
	defer cancel()

	configHash, err := s.applyFn(ctx, cfg)
	if err != nil {
		// Best-effort: a transient failure (netprobe not yet up / restarting) is retried on
		// the next connect or config change; the bootstrap file covers basic startup.
		s.logger.Debug().Err(err).Msg("Deferred netprobe desired-config apply (will retry on connect)")
		return
	}

	s.logger.Info().
		Str("config_hash", configHash).
		Int("device_bindings", len(cfg.GetDeviceBindings())).
		Msg("Applied desired visibility config to attached netprobe")
}

// SetAddonCommandClient installs the generic-contract command client. Safe to
// call before or after netprobe is up: the client dials lazily.
func (s *Sidecar) SetAddonCommandClient(client *AddonCommandClient) {
	s.addonCommands.Store(client)
}

// MatchBanners runs corpus matching for the agent's ACTIVE sweep banner grabs.
//
// It tries the generic AddonService.RunCommand contract first and falls back to
// the legacy NetprobeFrame IPC arm. Both paths are live deliberately:
// addons/netprobe declares `base_agent: ">=1.2.0"` -- a FLOOR, not a pin -- and
// the add-on ships as a pushed artifact on its own version line, so a new agent
// running against an older netprobe is a supported deployment rather than a
// transient during rollout. The IPC arm may only be deleted a release after the
// netprobe that implements RunCommand has converged across the fleet.
func (s *Sidecar) MatchBanners(ctx context.Context, batch *netprobepb.BannerBatch) (*netprobepb.BannerMatchBatch, error) {
	if commands := s.addonCommands.Load(); commands != nil {
		matches, err := commands.MatchBanners(ctx, batch)

		switch {
		case err == nil:
			return matches, nil
		case errors.Is(err, ErrAddonCommandUnavailable):
			// The expected state against a netprobe that predates the contract.
			// Checked BEFORE ctx: an absent socket is not a context problem, and
			// testing ctx first would report "cancelled" for a host that simply has
			// no command contract -- swallowing the fallback on every shutdown.
			// Debug, not warn: on an un-upgraded fleet this fires once per batch.
			s.logger.Debug().Err(err).
				Msg("Netprobe command contract unavailable; matching banners over legacy IPC")
		case ctx.Err() != nil:
			// The caller is shutting down or timed out. Falling back would block
			// on an IPC client that can no longer be waited for.
			return nil, err
		default:
			// netprobe HAS the socket and the call still failed. The fallback keeps
			// matching working, but this has to be visible or a real defect in the
			// new path hides behind the old one for a whole release.
			s.logger.Warn().Err(err).
				Msg("Netprobe RunCommand banner matching failed; falling back to legacy IPC")
		}
	}

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
		max = defaultFlowAttributionBuffer
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
		max = defaultFlowAttributionBuffer
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

// DroppedFlowAttributionEvents returns the cumulative number of
// FlowAttributionEvents dropped due to backpressure in either the IPC
// client buffer or the sidecar fan-in buffer.
func (s *Sidecar) DroppedFlowAttributionEvents() uint64 {
	dropped := s.droppedFlowAttributionEvents.Load()
	client := s.currentClient()
	if client == nil {
		return dropped
	}
	return dropped + client.DroppedFlowAttributionEvents()
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
	// A (re)connect re-delivers the desired config (no-op if none set), so a
	// systemd-restarted netprobe is reconfigured without waiting for a gateway poll.
	go s.pushDesired()
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
				s.droppedFlowAttributionEvents.Add(1)
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
