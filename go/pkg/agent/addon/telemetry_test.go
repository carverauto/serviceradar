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
	"bytes"
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/rs/zerolog"
)

type reconnectingTelemetryClient struct {
	calls atomic.Int32
}

func (c *reconnectingTelemetryClient) StreamTelemetry(
	ctx context.Context,
) (<-chan *coreaddon.TelemetryBatch, error) {
	call := c.calls.Add(1)
	batches := make(chan *coreaddon.TelemetryBatch, 1)

	if call == 1 {
		close(batches)
		return batches, nil
	}

	go func() {
		defer close(batches)
		select {
		case batches <- &addonpb.TelemetryBatch{
			Records: []*addonpb.TelemetryRecord{{EventId: "after-reconnect"}},
		}:
		case <-ctx.Done():
		}
	}()

	return batches, nil
}

type diagnosticTelemetryClient struct {
	diagnostics chan coreaddon.StreamDiagnostic
}

func (c *diagnosticTelemetryClient) StreamTelemetry(context.Context) (<-chan *coreaddon.TelemetryBatch, error) {
	batches := make(chan *coreaddon.TelemetryBatch)
	close(batches)

	select {
	case c.diagnostics <- coreaddon.StreamDiagnostic{
		Stream: "telemetry",
		Kind:   coreaddon.StreamEndError,
		Err:    errors.New("transport reset"),
	}:
	default:
	}

	return batches, nil
}

func (c *diagnosticTelemetryClient) StreamDiagnostics() <-chan coreaddon.StreamDiagnostic {
	return c.diagnostics
}

func TestRunnerDrainTelemetryReconnectsAfterStreamClose(t *testing.T) {
	handled := make(chan string, 1)
	client := &reconnectingTelemetryClient{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := applyDefaults(Config{
		RestartBackoffInitial: time.Millisecond,
		RestartBackoffMax:     time.Millisecond,
		Logger:                zerolog.Nop(),
		TelemetryHandler: func(_ string, batch *coreaddon.TelemetryBatch) {
			if records := batch.GetRecords(); len(records) > 0 {
				handled <- records[0].GetEventId()
			}
		},
	})
	r := newRunner(Spec{ID: "telemetry-addon"}, cfg)

	go r.drainTelemetry(ctx, client)

	select {
	case got := <-handled:
		if got != "after-reconnect" {
			t.Fatalf("event id = %q, want after-reconnect", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for telemetry after reconnect")
	}

	if got := client.calls.Load(); got < 2 {
		t.Fatalf("StreamTelemetry calls = %d, want at least 2", got)
	}
}

func TestRunnerDrainTelemetryLogsStreamLossDiagnostic(t *testing.T) {
	var logs bytes.Buffer
	client := &diagnosticTelemetryClient{
		diagnostics: make(chan coreaddon.StreamDiagnostic, 1),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()

	cfg := applyDefaults(Config{
		RestartBackoffInitial: time.Millisecond,
		RestartBackoffMax:     time.Millisecond,
		Logger:                zerolog.New(&logs),
	})
	r := newRunner(Spec{ID: "telemetry-addon"}, cfg)

	r.drainTelemetry(ctx, client)

	got := logs.String()
	if !strings.Contains(got, `"stream":"telemetry"`) {
		t.Fatalf("expected stream field in logs, got %s", got)
	}
	if !strings.Contains(got, `"stream_end":"error"`) {
		t.Fatalf("expected stream_end error in logs, got %s", got)
	}
	if !strings.Contains(got, "transport reset") {
		t.Fatalf("expected transport error in logs, got %s", got)
	}
}
