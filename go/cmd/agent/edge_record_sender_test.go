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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	"github.com/carverauto/serviceradar/go/pkg/logger"
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

func TestRunEdgeRecordSenderNoopWhenDisabled(t *testing.T) {
	t.Parallel()
	cfg := &agent.ServerConfig{EdgeRecordSender: &agent.EdgeRecordSenderConfig{Enabled: false}}
	mustReturnPromptly(t, func() {
		runEdgeRecordSender(context.Background(), cfg, logger.NewTestLogger())
	})
}

func TestRunEdgeRecordSenderRequiresGatewayAddr(t *testing.T) {
	t.Parallel()
	cfg := &agent.ServerConfig{
		EdgeRecordSender: &agent.EdgeRecordSenderConfig{
			Enabled:  true,
			SpoolDir: t.TempDir(),
		},
	}
	mustReturnPromptly(t, func() {
		runEdgeRecordSender(context.Background(), cfg, logger.NewTestLogger())
	})
}

func TestRunEdgeRecordSenderRequiresSpoolDir(t *testing.T) {
	t.Parallel()
	cfg := &agent.ServerConfig{
		GatewayAddr: "gateway.example.test:50052",
		EdgeRecordSender: &agent.EdgeRecordSenderConfig{
			Enabled: true,
		},
	}
	mustReturnPromptly(t, func() {
		runEdgeRecordSender(context.Background(), cfg, logger.NewTestLogger())
	})
}
