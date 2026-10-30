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

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/rs/zerolog"
)

// runEdgeRecordSender must return promptly (not block on a ticker or dial)
// whenever it is unconfigured or missing required fields, since it runs as a
// best-effort background goroutine alongside the push loop.
func mustReturnPromptly(t *testing.T, fn func()) {
	t.Helper()

	done := make(chan struct{})
	go func() {
		fn()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("did not return promptly")
	}
}

func TestRunEdgeRecordSenderNoopWhenNil(t *testing.T) {
	t.Parallel()
	cfg := &agent.ServerConfig{}
	mustReturnPromptly(t, func() {
		runEdgeRecordSender(context.Background(), cfg, nil, logger.NewTestLogger())
	})
}

type senderGuardLogger struct {
	logger.Logger
	output zerolog.Logger
}

func (l *senderGuardLogger) Error() *zerolog.Event { return l.output.Error() }

func TestRunEdgeRecordSenderConfigurationGuards(t *testing.T) {
	sp, err := spool.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	for _, tc := range []struct{ name, message string }{
		{"disabled", ""},
		{"address", "Edge record sender enabled without a gateway address"},
		{"spool", "Edge record sender enabled without a spool_dir"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "spool")
			cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{
				Enabled: true, GatewayAddr: "127.0.0.1:1", SpoolDir: dir,
				Security: &models.SecurityConfig{Mode: models.SecurityModeNone},
			}}
			switch tc.name {
			case "disabled":
				cfg.EdgeRecordSender.Enabled = false
			case "address":
				cfg.EdgeRecordSender.GatewayAddr = ""
			case "spool":
				cfg.EdgeRecordSender.SpoolDir = ""
			}
			var output bytes.Buffer
			log := &senderGuardLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			mustReturnPromptly(t, func() { runEdgeRecordSender(ctx, cfg, sp, log) })
			if tc.message == "" {
				if output.Len() != 0 {
					t.Fatalf("disabled sender emitted error: %s", output.String())
				}
			} else {
				var event struct {
					Message string `json:"message"`
				}
				if err := json.Unmarshal(output.Bytes(), &event); err != nil {
					t.Fatal(err)
				}
				if event.Message != tc.message {
					t.Fatalf("message = %q, want %q", event.Message, tc.message)
				}
			}
			if _, err := os.Stat(dir); !os.IsNotExist(err) {
				t.Fatalf("guard created spool: %v", err)
			}
		})
	}
}

func TestOpenEdgeRecordSpoolRejectsMissingDirectory(t *testing.T) {
	_, err := openEdgeRecordSpool(&agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{Enabled: true}})
	if err == nil {
		t.Fatal("enabled sender accepted missing spool directory")
	}
}

func TestOpenEdgeRecordSpoolRefusesAdmissionAtBudgetAfterRestart(t *testing.T) {
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{Enabled: true, SweepEnabled: true, SpoolDir: t.TempDir(), MaxBytes: 4 << 20}}
	sp, err := openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = sp.Append(make([]byte, 16), make([]byte, 1<<20)); err != nil {
		t.Fatal(err)
	}
	if err = sp.Close(); err != nil {
		t.Fatal(err)
	}
	sp, err = openEdgeRecordSpool(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	if _, err = sp.Append(make([]byte, 16), make([]byte, 1<<20)); !errors.Is(err, spool.ErrAdmissionRefused) {
		t.Fatalf("second append=%v, want byte-budget refusal", err)
	}
	records, err := sp.Unresolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("refused append changed spool: %d records", len(records))
	}
}

func TestRunEdgeRecordSenderRetriesSetupUntilSpoolDirAppears(t *testing.T) {
	sp, err := spool.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	dir := filepath.Join(t.TempDir(), "late-spool")
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{
		Enabled: true, GatewayAddr: "127.0.0.1:1", SpoolDir: dir,
		Security: &models.SecurityConfig{Mode: models.SecurityModeNone},
	}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runEdgeRecordSender(ctx, cfg, sp, logger.NewTestLogger())
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("sender stopped after its first setup failure")
	case <-time.After(200 * time.Millisecond):
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	idPath := filepath.Join(dir, "spool_id")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(idPath); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("sender never retried setup after the spool directory appeared")
		}
		time.Sleep(50 * time.Millisecond)
	}

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("sender did not stop after cancellation")
	}
}
