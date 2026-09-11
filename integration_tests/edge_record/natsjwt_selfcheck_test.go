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
