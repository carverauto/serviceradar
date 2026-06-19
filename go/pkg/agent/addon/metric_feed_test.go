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
	"errors"
	"io"
	"reflect"
	"sync"
	"testing"
	"time"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/rs/zerolog"
)

const testMetricFeedSourceSysmon = "sysmon"

func TestMetricFeedSourcesFromConfig(t *testing.T) {
	got := metricFeedSourcesFromConfig([]byte(`{
		"metric_feed": {"sources": ["sysmon-metrics", "snmp", "SNMP", "unknown"]},
		"metric_feed_sources": ["icmp-metrics", "timeseries"]
	}`))
	want := []string{testMetricFeedSourceSysmon, "snmp", "icmp", "timeseries"}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sources = %#v, want %#v", got, want)
	}
}

func TestMetricFeedLifecycleFiltersSourcesAndPublishesFrames(t *testing.T) {
	client := &recordingMetricFeedClient{received: make(chan *addonpb.MetricFeedFrame, 2)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lifecycle := newMetricFeedLifecycle(
		ctx,
		"anomaly",
		client,
		[]string{testMetricFeedSourceSysmon},
		zerolog.Nop(),
	)
	lifecycle.start()
	t.Cleanup(lifecycle.stop)

	if lifecycle.publish("snmp", []byte("snmp-batch")) {
		t.Fatal("unexpectedly accepted unsubscribed snmp source")
	}
	if !lifecycle.publish("sysmon-metrics", []byte("sysmon-batch")) {
		t.Fatal("expected sysmon frame to be accepted")
	}

	select {
	case got := <-client.received:
		if got.GetFeedId() != 1 {
			t.Fatalf("feed_id = %d, want 1", got.GetFeedId())
		}
		if got.GetSource().GetSourceType() != testMetricFeedSourceSysmon {
			t.Fatalf("source = %q, want %s", got.GetSource().GetSourceType(), testMetricFeedSourceSysmon)
		}
		if string(got.GetPayload()) != "sysmon-batch" {
			t.Fatalf("payload = %q, want sysmon-batch", got.GetPayload())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for metric feed frame")
	}
}

func TestMetricFeedLifecycleReconnectsAfterStreamClose(t *testing.T) {
	client := &reconnectingMetricFeedClient{
		opened:   make(chan int, 2),
		received: make(chan *addonpb.MetricFeedFrame, 1),
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lifecycle := newMetricFeedLifecycle(
		ctx,
		"anomaly",
		client,
		[]string{testMetricFeedSourceSysmon},
		zerolog.Nop(),
	)
	lifecycle.start()
	t.Cleanup(lifecycle.stop)

	waitForMetricFeedStream(t, client.opened, 1)
	waitForMetricFeedStream(t, client.opened, 2)

	if !lifecycle.publish("sysmon", []byte("after-reconnect")) {
		t.Fatal("expected publish to be accepted after reconnect")
	}

	select {
	case got := <-client.received:
		if got.GetFeedId() != 1 {
			t.Fatalf("feed_id = %d, want 1 after reconnect", got.GetFeedId())
		}
		if string(got.GetPayload()) != "after-reconnect" {
			t.Fatalf("payload = %q, want after-reconnect", got.GetPayload())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for metric feed frame after reconnect")
	}
}

func TestManagerPublishMetricFeedFiltersSources(t *testing.T) {
	client := &recordingMetricFeedClient{received: make(chan *addonpb.MetricFeedFrame, 2)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lifecycle := newMetricFeedLifecycle(
		ctx,
		"anomaly",
		client,
		[]string{testMetricFeedSourceSysmon},
		zerolog.Nop(),
	)
	lifecycle.start()
	t.Cleanup(lifecycle.stop)

	manager := NewManager(Config{})
	manager.runners["anomaly"] = &runner{metricFeed: lifecycle}

	if got := manager.PublishMetricFeed("snmp", []byte("snmp-batch")); got != 0 {
		t.Fatalf("unsubscribed publish accepted by %d add-ons, want 0", got)
	}
	if got := manager.PublishMetricFeed("sysmon-metrics", []byte("sysmon-batch")); got != 1 {
		t.Fatalf("subscribed publish accepted by %d add-ons, want 1", got)
	}

	select {
	case got := <-client.received:
		if got.GetSource().GetSourceType() != testMetricFeedSourceSysmon {
			t.Fatalf("source = %q, want %s", got.GetSource().GetSourceType(), testMetricFeedSourceSysmon)
		}
		if string(got.GetPayload()) != "sysmon-batch" {
			t.Fatalf("payload = %q, want sysmon-batch", got.GetPayload())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for manager-published metric feed frame")
	}
}

type recordingMetricFeedClient struct {
	received chan *addonpb.MetricFeedFrame
}

func (c *recordingMetricFeedClient) StreamMetricFeed(
	ctx context.Context,
) (chan<- *addonpb.MetricFeedFrame, <-chan uint64, error) {
	frames := make(chan *addonpb.MetricFeedFrame)
	acks := make(chan uint64)

	go func() {
		defer close(acks)
		for {
			select {
			case <-ctx.Done():
				return
			case frame, ok := <-frames:
				if !ok {
					return
				}
				select {
				case c.received <- frame:
				case <-ctx.Done():
					return
				}
				select {
				case acks <- frame.GetFeedId():
				case <-ctx.Done():
					return
				}
			}
		}
	}()

	return frames, acks, nil
}

type reconnectingMetricFeedClient struct {
	mu       sync.Mutex
	streams  int
	opened   chan int
	received chan *addonpb.MetricFeedFrame
}

func (c *reconnectingMetricFeedClient) StreamMetricFeed(
	ctx context.Context,
) (chan<- *addonpb.MetricFeedFrame, <-chan uint64, error) {
	c.mu.Lock()
	c.streams++
	streamID := c.streams
	c.mu.Unlock()

	frames := make(chan *addonpb.MetricFeedFrame)
	acks := make(chan uint64)
	c.opened <- streamID

	if streamID == 1 {
		close(acks)
		return frames, acks, nil
	}

	go func() {
		defer close(acks)
		for {
			select {
			case <-ctx.Done():
				return
			case frame, ok := <-frames:
				if !ok {
					return
				}
				select {
				case c.received <- frame:
				case <-ctx.Done():
					return
				}
				select {
				case acks <- frame.GetFeedId():
				case <-ctx.Done():
					return
				}
			}
		}
	}()

	return frames, acks, nil
}

type diagnosticMetricFeedClient struct {
	acks <-chan uint64
	errs <-chan error
	err  error
}

func (c diagnosticMetricFeedClient) StreamMetricFeed(
	context.Context,
) (chan<- *addonpb.MetricFeedFrame, <-chan uint64, error) {
	frames := make(chan *addonpb.MetricFeedFrame)
	return frames, c.acks, c.err
}

func (c diagnosticMetricFeedClient) StreamMetricFeedWithDiagnostics(
	context.Context,
) (chan<- *addonpb.MetricFeedFrame, <-chan uint64, <-chan error, error) {
	frames := make(chan *addonpb.MetricFeedFrame)
	return frames, c.acks, c.errs, c.err
}

func TestMetricFeedLifecycleReportsEOFAndTransportErrors(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	acks := make(chan uint64)
	errs := make(chan error, 1)
	errs <- io.EOF
	close(errs)
	close(acks)

	lifecycle := newMetricFeedLifecycle(
		ctx,
		"anomaly",
		diagnosticMetricFeedClient{acks: acks, errs: errs},
		[]string{testMetricFeedSourceSysmon},
		zerolog.Nop(),
	)
	err := lifecycle.runStream(ctx)
	if !errors.Is(err, errMetricFeedStreamClosed) {
		t.Fatalf("runStream error = %v, want metric feed stream closed", err)
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("runStream error = %v, want wrapped io.EOF", err)
	}

	transportErr := errors.New("metric feed transport reset")
	acks = make(chan uint64)
	errs = make(chan error, 1)
	errs <- transportErr
	close(errs)
	close(acks)

	lifecycle = newMetricFeedLifecycle(
		ctx,
		"anomaly",
		diagnosticMetricFeedClient{acks: acks, errs: errs},
		[]string{testMetricFeedSourceSysmon},
		zerolog.Nop(),
	)
	err = lifecycle.runStream(ctx)
	if !errors.Is(err, errMetricFeedStreamClosed) {
		t.Fatalf("runStream transport error = %v, want metric feed stream closed", err)
	}
	if !errors.Is(err, transportErr) {
		t.Fatalf("runStream transport error = %v, want wrapped transport error", err)
	}
}

func waitForMetricFeedStream(t *testing.T, opened <-chan int, want int) {
	t.Helper()

	select {
	case got := <-opened:
		if got != want {
			t.Fatalf("opened stream = %d, want %d", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for stream %d", want)
	}
}
