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
	"reflect"
	"sync/atomic"
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
		time.Millisecond,
		time.Millisecond,
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
		time.Millisecond,
		time.Millisecond,
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

func TestMetricFeedLifecycleReconnectsAfterAckStreamClose(t *testing.T) {
	client := &reconnectingMetricFeedClient{received: make(chan *addonpb.MetricFeedFrame, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lifecycle := newMetricFeedLifecycle(
		ctx,
		"anomaly",
		client,
		[]string{testMetricFeedSourceSysmon},
		zerolog.Nop(),
		time.Millisecond,
		time.Millisecond,
	)
	lifecycle.start()
	t.Cleanup(lifecycle.stop)

	waitForMetricFeedCalls(t, client, 2)

	if !lifecycle.publish("sysmon", []byte("sysmon-after-reconnect")) {
		t.Fatal("expected sysmon frame to be accepted after reconnect")
	}

	select {
	case got := <-client.received:
		if got.GetFeedId() != 1 {
			t.Fatalf("feed_id = %d, want reset-to-1 after reconnect", got.GetFeedId())
		}
		if string(got.GetPayload()) != "sysmon-after-reconnect" {
			t.Fatalf("payload = %q, want sysmon-after-reconnect", got.GetPayload())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for metric feed frame after reconnect")
	}

	if got := client.calls.Load(); got < 2 {
		t.Fatalf("StreamMetricFeed calls = %d, want at least 2", got)
	}
}

func waitForMetricFeedCalls(t *testing.T, client *reconnectingMetricFeedClient, want int32) {
	t.Helper()

	deadline := time.After(3 * time.Second)
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		if got := client.calls.Load(); got >= want {
			return
		}

		select {
		case <-deadline:
			t.Fatalf("StreamMetricFeed calls = %d, want at least %d", client.calls.Load(), want)
		case <-ticker.C:
		}
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
	calls    atomic.Int32
	received chan *addonpb.MetricFeedFrame
}

func (c *reconnectingMetricFeedClient) StreamMetricFeed(
	ctx context.Context,
) (chan<- *addonpb.MetricFeedFrame, <-chan uint64, error) {
	call := c.calls.Add(1)
	frames := make(chan *addonpb.MetricFeedFrame)
	acks := make(chan uint64)

	if call == 1 {
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
