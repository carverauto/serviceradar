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

package banner_grab

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	defaultConnectTimeout        = 2 * time.Second
	defaultReadTimeout           = 2 * time.Second
	defaultMaxBannerBytes        = 1024
	defaultMaxConcurrency        = 256
	defaultMaxConcurrencyPerHost = 4
	defaultCandidateQueue        = 8192
	defaultMinReprobeInterval    = 24 * time.Hour
	defaultPerHostRateLimit      = 100 * time.Millisecond
	defaultBackoff               = 5 * time.Minute
)

var errUnsupportedProtocol = errors.New("unsupported banner grab protocol")

// Config controls the active banner-grab phase.
type Config struct {
	Enabled               bool
	Protocols             []string
	Ports                 map[string][]int
	ConnectTimeout        time.Duration
	ReadTimeout           time.Duration
	MaxBannerBytes        int
	MaxConcurrencyPerHost int
	MaxGlobalConcurrency  int
	MaxProbeRatePerSecond int
	MaxCandidateQueue     int
	MatchBatchSize        int
	MatchBatchMaxBytes    int
	MinReprobeInterval    time.Duration
	PerHostRateLimit      time.Duration
	ForceRefresh          bool
	DialContext           DialContextFunc
	Now                   func() time.Time
}

// Stats is a snapshot of banner-grab phase counters.
type Stats struct {
	CandidatesTotal      uint64
	ProbesTotal          uint64
	ObservationsTotal    uint64
	SkippedFreshTotal    uint64
	SkippedBackoffTotal  uint64
	MatchBatchesTotal    uint64
	MatchBatchBytesTotal uint64
	BannerBytesTotal     uint64
	MatchesTotal         uint64
	EmptyResponseTotal   uint64
	ConnectionResetTotal uint64
	TimeoutTotal         uint64
	UnsupportedTotal     uint64
	ErrorsTotal          uint64
	InFlight             uint64
	QueueDepth           uint64
	MaxQueueDepth        uint64
}

// Engine runs bounded active probes over SYN-confirmed live targets.
type Engine struct {
	config     Config
	planner    *candidatePlanner
	probes     map[string]ProbeFunc
	candidates chan Candidate
	output     chan BannerObservation
	hostLimit  *hostLimiter
	rateLimit  *probeRateLimiter
	wg         sync.WaitGroup
	startOnce  sync.Once
	closeOnce  sync.Once
	nextID     uint64
	stats      Stats
}

func New(config Config) *Engine {
	config = normalizeConfig(config)

	engine := &Engine{
		config:     config,
		planner:    newCandidatePlanner(config, config.Now),
		probes:     defaultProbes(),
		candidates: make(chan Candidate, config.MaxCandidateQueue),
		output:     make(chan BannerObservation, config.MatchBatchSize),
		hostLimit:  newHostLimiter(config.MaxConcurrencyPerHost, config.PerHostRateLimit),
		rateLimit:  newProbeRateLimiter(config.MaxProbeRatePerSecond),
	}

	return engine
}

func ConfigFromModel(config models.BannerGrab) Config {
	return Config{
		Enabled:               config.Enabled,
		Protocols:             append([]string(nil), config.Protocols...),
		Ports:                 clonePorts(config.Ports),
		ConnectTimeout:        millisDuration(config.ConnectTimeoutMS),
		ReadTimeout:           millisDuration(config.ReadTimeoutMS),
		MaxBannerBytes:        config.MaxBannerBytes,
		MaxConcurrencyPerHost: config.MaxConcurrencyPerHost,
		MaxGlobalConcurrency:  config.MaxGlobalConcurrency,
		MaxProbeRatePerSecond: config.MaxProbeRatePerSecond,
		MaxCandidateQueue:     config.MaxCandidateQueue,
		MatchBatchSize:        config.MatchBatchSize,
		MatchBatchMaxBytes:    config.MatchBatchMaxBytes,
		MinReprobeInterval:    secondsDuration(config.MinReprobeIntervalSec),
		PerHostRateLimit:      millisDuration(config.PerHostRateLimitMillis),
	}
}

func (e *Engine) Start(ctx context.Context) <-chan BannerObservation {
	e.startOnce.Do(func() {
		for i := 0; i < e.config.MaxGlobalConcurrency; i++ {
			e.wg.Add(1)
			go e.worker(ctx)
		}

		go func() {
			e.wg.Wait()
			close(e.output)
		}()
	})

	return e.output
}

func (e *Engine) Stop() {
	e.closeOnce.Do(func() {
		close(e.candidates)
	})
}

func (e *Engine) Wait() {
	e.wg.Wait()
}

func (e *Engine) SubmitResult(ctx context.Context, result models.Result) error {
	if !e.config.Enabled || !result.Available {
		return nil
	}
	if result.Target.Mode != models.ModeTCP && result.Target.Mode != models.ModeTCPConnect {
		return nil
	}

	candidates, skippedFresh, skippedBackoff := e.planner.candidates(
		result.Target.Host,
		result.Target.Port,
		e.config.ForceRefresh,
	)
	if skippedFresh > 0 {
		atomic.AddUint64(&e.stats.SkippedFreshTotal, uint64(skippedFresh))
	}
	if skippedBackoff > 0 {
		atomic.AddUint64(&e.stats.SkippedBackoffTotal, uint64(skippedBackoff))
	}
	if len(candidates) == 0 {
		return nil
	}

	for _, candidate := range candidates {
		atomic.AddUint64(&e.stats.CandidatesTotal, 1)

		select {
		case e.candidates <- candidate:
			depth := uint64(len(e.candidates))
			atomic.StoreUint64(&e.stats.QueueDepth, depth)
			recordMaxStat(&e.stats.MaxQueueDepth, depth)
		case <-ctx.Done():
			return ctx.Err()
		}
	}

	return nil
}

func (e *Engine) Observations() <-chan BannerObservation {
	return e.output
}

func (e *Engine) Stats() Stats {
	return Stats{
		CandidatesTotal:      atomic.LoadUint64(&e.stats.CandidatesTotal),
		ProbesTotal:          atomic.LoadUint64(&e.stats.ProbesTotal),
		ObservationsTotal:    atomic.LoadUint64(&e.stats.ObservationsTotal),
		SkippedFreshTotal:    atomic.LoadUint64(&e.stats.SkippedFreshTotal),
		SkippedBackoffTotal:  atomic.LoadUint64(&e.stats.SkippedBackoffTotal),
		MatchBatchesTotal:    atomic.LoadUint64(&e.stats.MatchBatchesTotal),
		MatchBatchBytesTotal: atomic.LoadUint64(&e.stats.MatchBatchBytesTotal),
		BannerBytesTotal:     atomic.LoadUint64(&e.stats.BannerBytesTotal),
		MatchesTotal:         atomic.LoadUint64(&e.stats.MatchesTotal),
		EmptyResponseTotal:   atomic.LoadUint64(&e.stats.EmptyResponseTotal),
		ConnectionResetTotal: atomic.LoadUint64(&e.stats.ConnectionResetTotal),
		TimeoutTotal:         atomic.LoadUint64(&e.stats.TimeoutTotal),
		UnsupportedTotal:     atomic.LoadUint64(&e.stats.UnsupportedTotal),
		ErrorsTotal:          atomic.LoadUint64(&e.stats.ErrorsTotal),
		InFlight:             atomic.LoadUint64(&e.stats.InFlight),
		QueueDepth:           atomic.LoadUint64(&e.stats.QueueDepth),
		MaxQueueDepth:        atomic.LoadUint64(&e.stats.MaxQueueDepth),
	}
}

func (e *Engine) RecordMatchBatch(bytes int, matches int) {
	if e == nil {
		return
	}
	atomic.AddUint64(&e.stats.MatchBatchesTotal, 1)
	if bytes > 0 {
		atomic.AddUint64(&e.stats.MatchBatchBytesTotal, uint64(bytes))
	}
	if matches > 0 {
		atomic.AddUint64(&e.stats.MatchesTotal, uint64(matches))
	}
}

func (e *Engine) worker(ctx context.Context) {
	defer e.wg.Done()

	for {
		select {
		case <-ctx.Done():
			return
		case candidate, ok := <-e.candidates:
			if !ok {
				return
			}

			atomic.StoreUint64(&e.stats.QueueDepth, uint64(len(e.candidates)))
			e.probeCandidate(ctx, candidate)
		}
	}
}

func (e *Engine) probeCandidate(ctx context.Context, candidate Candidate) {
	probe := e.probes[candidate.Protocol]
	if probe == nil {
		atomic.AddUint64(&e.stats.UnsupportedTotal, 1)
		return
	}

	release, err := e.hostLimit.acquire(ctx, candidate.Host)
	if err != nil {
		return
	}
	defer release()

	if err := e.rateLimit.wait(ctx); err != nil {
		return
	}

	atomic.AddUint64(&e.stats.InFlight, 1)
	atomic.AddUint64(&e.stats.ProbesTotal, 1)
	defer atomic.AddUint64(&e.stats.InFlight, ^uint64(0))

	observation, err := probe(ctx, candidate.Host, candidate.Port, ProbeOpts{
		ConnectTimeout: e.config.ConnectTimeout,
		ReadTimeout:    e.config.ReadTimeout,
		MaxBannerBytes: e.config.MaxBannerBytes,
		DialContext:    e.config.DialContext,
		Now:            e.config.Now,
	})
	if err != nil {
		e.recordProbeError(candidate, err)
		return
	}
	if len(observation.BannerBytes) == 0 {
		atomic.AddUint64(&e.stats.EmptyResponseTotal, 1)
		e.planner.recordBackoff(candidate, defaultBackoff)
		return
	}

	e.planner.recordSuccess(candidate, observation.ObservedAt)
	observation.ObservationID = atomic.AddUint64(&e.nextID, 1)
	atomic.AddUint64(&e.stats.ObservationsTotal, 1)
	atomic.AddUint64(&e.stats.BannerBytesTotal, uint64(len(observation.BannerBytes)))

	select {
	case e.output <- observation:
	case <-ctx.Done():
	}
}

func (e *Engine) recordProbeError(candidate Candidate, err error) {
	switch {
	case errors.Is(err, errUnsupportedProtocol):
		atomic.AddUint64(&e.stats.UnsupportedTotal, 1)
	case isTimeout(err):
		atomic.AddUint64(&e.stats.TimeoutTotal, 1)
		e.planner.recordBackoff(candidate, defaultBackoff)
	case isReset(err):
		atomic.AddUint64(&e.stats.ConnectionResetTotal, 1)
		e.planner.recordBackoff(candidate, defaultBackoff)
	default:
		atomic.AddUint64(&e.stats.ErrorsTotal, 1)
		e.planner.recordBackoff(candidate, defaultBackoff)
	}
}

func normalizeConfig(config Config) Config {
	if config.ConnectTimeout <= 0 {
		config.ConnectTimeout = defaultConnectTimeout
	}
	if config.ReadTimeout <= 0 {
		config.ReadTimeout = defaultReadTimeout
	}
	if config.MaxBannerBytes <= 0 {
		config.MaxBannerBytes = defaultMaxBannerBytes
	}
	if config.MaxGlobalConcurrency <= 0 {
		config.MaxGlobalConcurrency = defaultMaxConcurrency
	}
	if config.MaxConcurrencyPerHost <= 0 {
		config.MaxConcurrencyPerHost = defaultMaxConcurrencyPerHost
	}
	if config.MaxCandidateQueue <= 0 {
		config.MaxCandidateQueue = defaultCandidateQueue
	}
	if config.MatchBatchSize <= 0 {
		config.MatchBatchSize = 256
	}
	if config.MatchBatchMaxBytes <= 0 {
		config.MatchBatchMaxBytes = 1024 * 1024
	}
	if config.MinReprobeInterval <= 0 {
		config.MinReprobeInterval = defaultMinReprobeInterval
	}
	if config.PerHostRateLimit <= 0 {
		config.PerHostRateLimit = defaultPerHostRateLimit
	}

	return config
}

func (c Config) portProtocols() map[int][]string {
	portsByProtocol := c.Ports
	if len(portsByProtocol) == 0 {
		portsByProtocol = defaultPorts()
	}

	out := make(map[int][]string)
	for _, protocol := range c.Protocols {
		ports := portsByProtocol[protocol]
		if len(ports) == 0 {
			ports = defaultPorts()[protocol]
		}

		for _, port := range ports {
			if port <= 0 {
				continue
			}
			out[port] = append(out[port], protocol)
		}
	}

	return out
}

func defaultProbes() map[string]ProbeFunc {
	return map[string]ProbeFunc{
		ProtocolSSH:    ProbeSSH,
		ProtocolHTTP:   ProbeHTTP,
		ProtocolSMB:    ProbeSMB,
		ProtocolFTP:    ProbeFTP,
		ProtocolTelnet: ProbeTelnet,
		ProtocolSMTP:   ProbeSMTP,
		ProtocolNTP:    ProbeNTP,
		ProtocolDNS:    ProbeDNS,
		ProtocolRDP:    ProbeRDP,
	}
}

func defaultPorts() map[string][]int {
	return map[string][]int{
		ProtocolSSH:    {22},
		ProtocolHTTP:   {80, 8080, 8000, 8888},
		ProtocolSMB:    {445},
		ProtocolFTP:    {21},
		ProtocolTelnet: {23},
		ProtocolSMTP:   {25, 587},
		ProtocolNTP:    {123},
		ProtocolDNS:    {53},
		ProtocolRDP:    {3389},
	}
}

func clonePorts(in map[string][]int) map[string][]int {
	if in == nil {
		return nil
	}

	out := make(map[string][]int, len(in))
	for protocol, ports := range in {
		out[protocol] = append([]int(nil), ports...)
	}

	return out
}

func millisDuration(value int) time.Duration {
	if value <= 0 {
		return 0
	}

	return time.Duration(value) * time.Millisecond
}

func secondsDuration(value int) time.Duration {
	if value <= 0 {
		return 0
	}

	return time.Duration(value) * time.Second
}

func recordMaxStat(max *uint64, candidate uint64) {
	for {
		current := atomic.LoadUint64(max)
		if candidate <= current {
			return
		}

		if atomic.CompareAndSwapUint64(max, current, candidate) {
			return
		}
	}
}
