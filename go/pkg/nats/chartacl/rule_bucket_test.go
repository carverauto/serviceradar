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

package chartacl

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	datasvcSubject      = "CN=serviceradar-datasvc,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
	logCollectorSubject = "CN=serviceradar-log-collector,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"

	ruleBucket    = "serviceradar-zen-rules"
	datasvcBucket = "serviceradar-datasvc"
	ruleKey       = "zen/rulesets/events/logs.syslog.json"
)

// TestChartRuleBucketPermissions checks the Zen rule bucket grants on the
// broker the chart configures, with a JetStream client doing what each
// identity does: core creates the bucket and writes bundles, web-ng writes the
// bundle of a rule saved there, and the log collector reads and watches its
// bundle while it keeps creating, updating and publishing to the events
// stream. The collector reaches no other key-value bucket and cannot write
// bundles.
func TestChartRuleBucketPermissions(t *testing.T) {
	pki := newTestPKI(t)
	rendered := renderChart(t, pki, nil)
	srv := startServer(t, rendered.conf)

	core := jetStreamAs(t, pki, srv, coreSubject)
	rules, err := core.CreateKeyValue(t.Context(), jetstream.KeyValueConfig{
		Bucket:   ruleBucket,
		History:  1,
		MaxBytes: 1 << 20,
		Storage:  jetstream.FileStorage,
	})
	if err != nil {
		t.Fatalf("core creates the rule bucket: %v", err)
	}

	if _, err := rules.Put(t.Context(), ruleKey, []byte(`{"digest":"sha256:core"}`)); err != nil {
		t.Fatalf("core writes a bundle: %v", err)
	}

	webNg := jetStreamAs(t, pki, srv, webNgSubject)

	webNgRules, err := webNg.KeyValue(t.Context(), ruleBucket)
	if err != nil {
		t.Fatalf("web-ng opens the rule bucket: %v", err)
	}

	if _, err := webNgRules.Put(t.Context(), ruleKey, []byte(`{"digest":"sha256:web-ng"}`)); err != nil {
		t.Fatalf("web-ng writes a bundle: %v", err)
	}

	agentConfig := jetStreamAs(t, pki, srv, datasvcSubject)

	datasvc, err := agentConfig.CreateKeyValue(t.Context(), jetstream.KeyValueConfig{Bucket: datasvcBucket, MaxBytes: 1 << 20})
	if err != nil {
		t.Fatalf("create the datasvc bucket: %v", err)
	}

	if _, err := datasvc.Put(t.Context(), "agents/agent01/config.json", []byte(`{"synthetic":true}`)); err != nil {
		t.Fatalf("write agent configuration: %v", err)
	}

	collectorConn, denied := pki.connectTracked(t, srv, logCollectorSubject)

	collector, err := jetstream.New(collectorConn)
	if err != nil {
		t.Fatalf("collector JetStream context: %v", err)
	}

	assertCollectorFollowsBundle(t, collector, rules)
	assertCollectorOwnsEventsStream(t, collector)

	if len(denied.all()) != 0 {
		t.Fatalf("the collector's own work was denied: %v", denied.all())
	}

	assertCollectorDenied(t, collector, denied)
}

func jetStreamAs(t *testing.T, pki *testPKI, srv *server.Server, dn string) jetstream.JetStream {
	t.Helper()

	js, err := jetstream.New(pki.connect(t, srv, dn, nil))
	if err != nil {
		t.Fatalf("JetStream context for %s: %v", dn, err)
	}

	return js
}

func assertCollectorFollowsBundle(t *testing.T, collector jetstream.JetStream, written jetstream.KeyValue) {
	t.Helper()

	rules, err := collector.KeyValue(t.Context(), ruleBucket)
	if err != nil {
		t.Fatalf("collector opens the rule bucket: %v", err)
	}

	entry, err := rules.Get(t.Context(), ruleKey)
	if err != nil {
		t.Fatalf("collector fetches its bundle: %v", err)
	}

	if string(entry.Value()) != `{"digest":"sha256:web-ng"}` {
		t.Fatalf("collector fetched %q", entry.Value())
	}

	watcher, err := rules.Watch(t.Context(), ruleKey, jetstream.UpdatesOnly())
	if err != nil {
		t.Fatalf("collector watches its bundle: %v", err)
	}

	defer func() { _ = watcher.Stop() }()

	if _, err := written.Put(t.Context(), ruleKey, []byte(`{"digest":"sha256:next"}`)); err != nil {
		t.Fatalf("core writes the next bundle: %v", err)
	}

	select {
	case update := <-watcher.Updates():
		if update == nil || string(update.Value()) != `{"digest":"sha256:next"}` {
			t.Fatalf("collector watched %v", update)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("collector's watch delivered no update")
	}
}

func assertCollectorOwnsEventsStream(t *testing.T, collector jetstream.JetStream) {
	t.Helper()

	config := jetstream.StreamConfig{Name: "events", Subjects: []string{"logs.syslog"}, MaxBytes: 1 << 20}

	if _, err := collector.CreateStream(t.Context(), config); err != nil {
		t.Fatalf("collector creates the events stream: %v", err)
	}

	config.Subjects = append(config.Subjects, "logs.normalized.syslog", "logs.otel", "otel.traces.raw")

	if _, err := collector.UpdateStream(t.Context(), config); err != nil {
		t.Fatalf("collector updates the events stream: %v", err)
	}

	for _, subject := range config.Subjects {
		if _, err := collector.Publish(t.Context(), subject, []byte(`{"synthetic":true}`)); err != nil {
			t.Fatalf("collector publishes %s: %v", subject, err)
		}
	}
}

func assertCollectorDenied(t *testing.T, collector jetstream.JetStream, denied *violations) {
	t.Helper()

	attempts := []struct {
		subject string
		try     func(context.Context) error
	}{
		{"$KV." + ruleBucket + "." + ruleKey, func(ctx context.Context) error {
			_, err := collector.Publish(ctx, "$KV."+ruleBucket+"."+ruleKey, []byte(`{"forged":true}`))
			return err
		}},
		{"$JS.API.STREAM.INFO.KV_" + datasvcBucket, func(ctx context.Context) error {
			_, err := collector.KeyValue(ctx, datasvcBucket)
			return err
		}},
		{"$JS.API.STREAM.PURGE.KV_" + ruleBucket, func(ctx context.Context) error {
			stream, err := collector.Stream(ctx, "KV_"+ruleBucket)
			if err != nil {
				return err
			}

			return stream.Purge(ctx)
		}},
	}

	for _, attempt := range attempts {
		ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
		err := attempt.try(ctx)

		cancel()

		if err == nil {
			t.Errorf("collector was allowed %s", attempt.subject)
		}

		if !denied.waitFor(attempt.subject, 5*time.Second) {
			t.Errorf("expected a permissions violation for %s, got %v", attempt.subject, denied.all())
		}
	}
}
