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
	"context"
 "bytes"
 "encoding/json"
 "os"
 "path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
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
		runEdgeRecordSender(context.Background(), cfg, logger.NewTestLogger())
	})
}

type senderGuardLogger struct {
 logger.Logger
 output zerolog.Logger
}

func (l *senderGuardLogger) Error() *zerolog.Event { return l.output.Error() }

func TestRunEdgeRecordSenderConfigurationGuards(t *testing.T) {
 for _, tc := range []struct { name, message string }{
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
   case "disabled": cfg.EdgeRecordSender.Enabled = false
   case "address": cfg.EdgeRecordSender.GatewayAddr = ""
   case "spool": cfg.EdgeRecordSender.SpoolDir = ""
   }
   var output bytes.Buffer
   log := &senderGuardLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)}
   ctx, cancel := context.WithTimeout(context.Background(), time.Second)
   defer cancel()
   mustReturnPromptly(t, func() { runEdgeRecordSender(ctx, cfg, log) })
   if tc.message == "" {
    if output.Len() != 0 { t.Fatalf("disabled sender emitted error: %s", output.String()) }
   } else {
    var event struct { Message string `json:"message"` }
    if err := json.Unmarshal(output.Bytes(), &event); err != nil { t.Fatal(err) }
    if event.Message != tc.message { t.Fatalf("message = %q, want %q", event.Message, tc.message) }
   }
   if _, err := os.Stat(dir); !os.IsNotExist(err) { t.Fatalf("guard created spool: %v", err) }
  })
 }
}
