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

package addon

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/rs/zerolog"
)

const (
	defaultMetricFeedQueueDepth  = 64
	defaultMetricFeedMaxInFlight = 32
	metricFeedPollInterval       = 10 * time.Millisecond
)

type metricFeedPublication struct {
	source  string
	payload []byte
}

type metricFeedStream struct {
	frames chan<- *addonpb.MetricFeedFrame
	acks   <-chan uint64
}

type metricFeedLifecycle struct {
	parent                  context.Context
	addonID                 string
	client                  coreaddon.MetricFeedClient
	sources                 map[string]struct{}
	logger                  zerolog.Logger
	initialReconnectBackoff time.Duration
	maxReconnectBackoff     time.Duration

	queue chan metricFeedPublication

	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

func newMetricFeedLifecycle(
	parent context.Context,
	addonID string,
	client coreaddon.MetricFeedClient,
	sources []string,
	logger zerolog.Logger,
	initialReconnectBackoff time.Duration,
	maxReconnectBackoff time.Duration,
) *metricFeedLifecycle {
	normalized := make(map[string]struct{}, len(sources))
	for _, source := range sources {
		if canonical := canonicalMetricFeedSource(source); canonical != "" {
			normalized[canonical] = struct{}{}
		}
	}

	return &metricFeedLifecycle{
		parent:                  parent,
		addonID:                 addonID,
		client:                  client,
		sources:                 normalized,
		logger:                  logger,
		initialReconnectBackoff: initialReconnectBackoff,
		maxReconnectBackoff:     maxReconnectBackoff,
		queue:                   make(chan metricFeedPublication, defaultMetricFeedQueueDepth),
	}
}

func (l *metricFeedLifecycle) start() {
	if l == nil || len(l.sources) == 0 {
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if l.cancel != nil || l.parent.Err() != nil {
		return
	}

	ctx, cancel := context.WithCancel(l.parent)
	done := make(chan struct{})
	l.cancel = cancel
	l.done = done

	go func() {
		defer close(done)
		defer l.markDone(done)
		l.run(ctx)
	}()
}

func (l *metricFeedLifecycle) stop() {
	if l == nil {
		return
	}

	l.mu.Lock()
	cancel, done := l.cancel, l.done
	l.cancel, l.done = nil, nil
	l.mu.Unlock()

	if cancel == nil {
		return
	}
	cancel()
	<-done
}

func (l *metricFeedLifecycle) markDone(done chan struct{}) {
	l.mu.Lock()
	if l.done == done {
		l.cancel = nil
		l.done = nil
	}
	l.mu.Unlock()
}

func (l *metricFeedLifecycle) publish(source string, payload []byte) bool {
	if l == nil || len(payload) == 0 {
		return false
	}

	canonical := canonicalMetricFeedSource(source)
	if canonical == "" {
		return false
	}
	if _, ok := l.sources[canonical]; !ok {
		return false
	}

	l.mu.Lock()
	active := l.cancel != nil
	l.mu.Unlock()
	if !active {
		return false
	}

	copied := append([]byte(nil), payload...)
	select {
	case l.queue <- metricFeedPublication{source: canonical, payload: copied}:
		return true
	default:
		l.logger.Debug().
			Str("addon", l.addonID).
			Str("source", canonical).
			Msg("Dropped add-on metric feed frame because queue is full")
		return false
	}
}

func (l *metricFeedLifecycle) run(ctx context.Context) {
	diagnostics := streamDiagnostics(l.client)

	reconnectStreamLoop(
		ctx,
		l.initialReconnectBackoff,
		l.maxReconnectBackoff,
		func(ctx context.Context) (metricFeedStream, error) {
			frames, acks, err := l.client.StreamMetricFeed(ctx)
			return metricFeedStream{frames: frames, acks: acks}, err
		},
		func(ctx context.Context, stream metricFeedStream) bool {
			madeProgress := l.runStream(ctx, stream.frames, stream.acks)
			close(stream.frames)
			return madeProgress
		},
		func(err error, delay time.Duration) {
			l.logger.Warn().
				Err(err).
				Str("addon", l.addonID).
				Dur("retry_after", delay).
				Msg("addon metric feed stream failed to open")
		},
		func(delay time.Duration) {
			diagnostic := readStreamDiagnostic(diagnostics)
			event := l.logger.Warn().
				Str("addon", l.addonID).
				Str("stream", "metric_feed").
				Str("stream_end", string(diagnostic.Kind)).
				Dur("retry_after", delay)
			if diagnostic.Err != nil {
				event = event.Err(diagnostic.Err)
			}
			event.Msg("addon metric feed stream closed; reconnecting")
		},
	)
}

func (l *metricFeedLifecycle) runStream(
	ctx context.Context,
	frames chan<- *addonpb.MetricFeedFrame,
	acks <-chan uint64,
) bool {
	var madeProgress atomic.Bool
	var acked atomic.Uint64
	ackDone := make(chan struct{})

	go func() {
		defer close(ackDone)
		for {
			select {
			case <-ctx.Done():
				return
			case ack, ok := <-acks:
				if !ok {
					return
				}
				acked.Store(ack)
				madeProgress.Store(true)
			}
		}
	}()

	var seq uint64
	for {
		select {
		case <-ctx.Done():
			return madeProgress.Load()
		case <-ackDone:
			return madeProgress.Load()
		case publication := <-l.queue:
			nextID := seq + 1
			for nextID-acked.Load() > defaultMetricFeedMaxInFlight {
				select {
				case <-ctx.Done():
					return madeProgress.Load()
				case <-ackDone:
					return madeProgress.Load()
				case <-time.After(metricFeedPollInterval):
				}
			}

			frame := &addonpb.MetricFeedFrame{
				FeedId: nextID,
				Source: &addonpb.TelemetrySource{
					SourceType:     publication.source,
					SourceInstance: "agent-local",
					Metadata: map[string]string{
						"contract": coreaddon.CapabilityMetricFeedV1,
					},
				},
				Payload: publication.payload,
			}

			select {
			case <-ctx.Done():
				return madeProgress.Load()
			case <-ackDone:
				return madeProgress.Load()
			case frames <- frame:
				seq = nextID
				madeProgress.Store(true)
			}
		}
	}
}

func metricFeedSourcesFromConfig(configJSON []byte) []string {
	if len(configJSON) == 0 {
		return nil
	}

	var decoded struct {
		MetricFeed struct {
			Sources []string `json:"sources"`
		} `json:"metric_feed"`
		MetricFeedSources []string `json:"metric_feed_sources"`
	}
	if err := json.Unmarshal(configJSON, &decoded); err != nil {
		return nil
	}

	sources := append([]string(nil), decoded.MetricFeed.Sources...)
	sources = append(sources, decoded.MetricFeedSources...)

	seen := make(map[string]struct{}, len(sources))
	normalized := make([]string, 0, len(sources))
	for _, source := range sources {
		canonical := canonicalMetricFeedSource(source)
		if canonical == "" {
			continue
		}
		if _, ok := seen[canonical]; ok {
			continue
		}
		seen[canonical] = struct{}{}
		normalized = append(normalized, canonical)
	}

	return normalized
}

func canonicalMetricFeedSource(source string) string {
	switch strings.ToLower(strings.TrimSpace(source)) {
	case "sysmon", "sysmon-metrics":
		return "sysmon"
	case "snmp", "snmp-metrics":
		return "snmp"
	case "icmp", "icmp-metrics":
		return "icmp"
	case "timeseries", "timeseries-metrics":
		return "timeseries"
	default:
		return ""
	}
}
