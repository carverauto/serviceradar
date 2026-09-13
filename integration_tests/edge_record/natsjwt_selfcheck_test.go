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

package verticalslice

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// TestStartEmbeddedNATSJetStreamRoundTrip proves the JWT trust chain
// actually works: a real nats.go client authenticates with the generated
// .creds file, creates a JetStream stream, publishes, and reads the message
// back, exactly the capability AGENT_GATEWAY_NATS_CREDS_FILE /
// EVENT_WRITER_NATS_CREDS_FILE need in the real harness.
func TestStartEmbeddedNATSJetStreamRoundTrip(t *testing.T) {
	dir := t.TempDir()

	h, err := StartEmbeddedNATS(filepath.Join(dir, "store"), filepath.Join(dir, "creds"))
	if err != nil {
		t.Fatalf("StartEmbeddedNATS: %v", err)
	}
	t.Cleanup(h.Shutdown)

	nc, err := nats.Connect(h.URL, nats.UserCredentials(h.CredsPath))
	if err != nil {
		t.Fatalf("nats.Connect: %v", err)
	}
	t.Cleanup(nc.Close)

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("jetstream.New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := js.CreateStream(ctx, jetstream.StreamConfig{
		Name:     "VSLICE_SELFCHECK",
		Subjects: []string{"vslice.selfcheck.>"},
	})
	if err != nil {
		t.Fatalf("CreateStream: %v", err)
	}

	if _, err := js.Publish(ctx, "vslice.selfcheck.one", []byte("hello")); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	consumer, err := stream.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Durable:   "vslice_selfcheck_consumer",
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		t.Fatalf("CreateOrUpdateConsumer: %v", err)
	}

	msg, err := consumer.Next(jetstream.FetchMaxWait(5 * time.Second))
	if err != nil {
		t.Fatalf("consumer.Next: %v", err)
	}
	if string(msg.Data()) != "hello" {
		t.Fatalf("got %q, want %q", msg.Data(), "hello")
	}
	if err := msg.Ack(); err != nil {
		t.Fatalf("Ack: %v", err)
	}
}

// TestEmbeddedNATSRestartPreservesTrust proves NATSHarness.Restart brings
// the broker back with the SAME identity: the URL is unchanged (same
// client port), the pre-restart .creds file still authenticates (same
// operator/account/user JWT chain), and a message persisted to the
// JetStream file store before Shutdown survives the restart.
func TestEmbeddedNATSRestartPreservesTrust(t *testing.T) {
	dir := t.TempDir()

	h, err := StartEmbeddedNATS(filepath.Join(dir, "store"), filepath.Join(dir, "creds"))
	if err != nil {
		t.Fatalf("StartEmbeddedNATS: %v", err)
	}
	t.Cleanup(h.Shutdown)
	beforeURL := h.URL

	nc, err := nats.Connect(h.URL, nats.UserCredentials(h.CredsPath))
	if err != nil {
		t.Fatalf("nats.Connect before restart: %v", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("jetstream.New before restart: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := js.CreateStream(ctx, jetstream.StreamConfig{
		Name:     "VSLICE_RESTART_SELFCHECK",
		Subjects: []string{"vslice.restart.>"},
	}); err != nil {
		t.Fatalf("CreateStream before restart: %v", err)
	}
	if _, err := js.Publish(ctx, "vslice.restart.one", []byte("persist-me")); err != nil {
		t.Fatalf("Publish before restart: %v", err)
	}
	nc.Close()

	h.Shutdown()
	if h.Server != nil {
		t.Fatalf("Shutdown left Server non-nil")
	}

	if err := h.Restart(); err != nil {
		t.Fatalf("Restart: %v", err)
	}
	if h.Server == nil {
		t.Fatalf("Restart left Server nil")
	}
	if h.URL != beforeURL {
		t.Fatalf("Restart changed URL: was %s, now %s (releases redial the same address)", beforeURL, h.URL)
	}

	// The SAME .creds file must still authenticate: a fresh trust chain
	// would reject it.
	nc2, err := nats.Connect(h.URL, nats.UserCredentials(h.CredsPath))
	if err != nil {
		t.Fatalf("nats.Connect after restart with pre-restart creds: %v", err)
	}
	t.Cleanup(nc2.Close)

	js2, err := jetstream.New(nc2)
	if err != nil {
		t.Fatalf("jetstream.New after restart: %v", err)
	}

	ctx2, cancel2 := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel2()

	stream2, err := js2.Stream(ctx2, "VSLICE_RESTART_SELFCHECK")
	if err != nil {
		t.Fatalf("Stream after restart (persisted store did not survive): %v", err)
	}
	consumer, err := stream2.CreateOrUpdateConsumer(ctx2, jetstream.ConsumerConfig{
		Durable:   "vslice_restart_selfcheck_consumer",
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		t.Fatalf("CreateOrUpdateConsumer after restart: %v", err)
	}
	msg, err := consumer.Next(jetstream.FetchMaxWait(5 * time.Second))
	if err != nil {
		t.Fatalf("consumer.Next after restart (pre-restart message lost): %v", err)
	}
	if string(msg.Data()) != "persist-me" {
		t.Fatalf("got %q, want %q", msg.Data(), "persist-me")
	}
	if err := msg.Ack(); err != nil {
		t.Fatalf("Ack after restart: %v", err)
	}
}

// TestEmbeddedNATSRestartRefusesLiveServer proves Restart does not
// silently overlap a cut with its restore: it fails loudly unless Shutdown
// ran first.
func TestEmbeddedNATSRestartRefusesLiveServer(t *testing.T) {
	dir := t.TempDir()

	h, err := StartEmbeddedNATS(filepath.Join(dir, "store"), filepath.Join(dir, "creds"))
	if err != nil {
		t.Fatalf("StartEmbeddedNATS: %v", err)
	}
	t.Cleanup(h.Shutdown)

	if err := h.Restart(); err == nil {
		t.Fatalf("Restart with live server succeeded, want an error (Shutdown first)")
	}
}

// TestStartEmbeddedNATSAcceptsEventWriterReservations creates file streams
// with the max_bytes the core EventWriter declares for its largest streams
// (ServiceRadar.EventWriter.Config: flows 10 GiB, events 8 GiB, the
// edge-record stream 1 GiB). The EventWriter treats a rejected stream as a
// failed connection and then consumes nothing, so each must be accepted.
func TestStartEmbeddedNATSAcceptsEventWriterReservations(t *testing.T) {
	dir := t.TempDir()

	h, err := StartEmbeddedNATS(filepath.Join(dir, "store"), filepath.Join(dir, "creds"))
	if err != nil {
		t.Fatalf("StartEmbeddedNATS: %v", err)
	}
	t.Cleanup(h.Shutdown)

	nc, err := nats.Connect(h.URL, nats.UserCredentials(h.CredsPath))
	if err != nil {
		t.Fatalf("nats.Connect: %v", err)
	}
	t.Cleanup(nc.Close)

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("jetstream.New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const gib = int64(1024 * 1024 * 1024)
	for _, cfg := range []jetstream.StreamConfig{
		{Name: "flows", Subjects: []string{"flows.raw.>"}, MaxBytes: 10 * gib},
		{Name: "events", Subjects: []string{"events.>"}, MaxBytes: 8 * gib},
		{Name: "TELEMETRY_EDGE_RECORD_V1_BULK", Subjects: []string{"telemetry.edge-record.v1.bulk.>"}, MaxBytes: gib},
	} {
		cfg.Storage = jetstream.FileStorage
		if _, err := js.CreateStream(ctx, cfg); err != nil {
			t.Fatalf("CreateStream %s (max_bytes %d): %v", cfg.Name, cfg.MaxBytes, err)
		}
	}
}
