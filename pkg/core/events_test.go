/*
 * Copyright 2025 Carver Automation Corporation.
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

package core

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestEventPublisherReinitializesAfterConnectionClose(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	jsServer := runJetStreamServer(t)
	t.Cleanup(func() {
		jsServer.Shutdown()
	})

	config := &models.CoreServiceConfig{
		Events: &models.EventsConfig{
			Enabled:    true,
			StreamName: "events",
			Subjects:   []string{"events.poller.health"},
		},
		NATS: &models.NATSConfig{
			URL: jsServer.ClientURL(),
		},
	}

	server := &Server{
		ShutdownChan: make(chan struct{}),
		logger:       logger.NewTestLogger(),
		config:       config,
	}

	require.NoError(t, server.initializeEventPublisher(ctx, config))

	require.Eventually(t, func() bool {
		server.mu.RLock()
		defer server.mu.RUnlock()
		return server.natsConn != nil && server.natsConn.Status() == nats.CONNECTED
	}, 5*time.Second, 50*time.Millisecond, "initial NATS connection not established")

	server.mu.RLock()
	originalConn := server.natsConn
	server.mu.RUnlock()
	require.NotNil(t, originalConn, "expected initial NATS connection")

	originalConn.Close()

	require.Eventually(t, func() bool {
		server.mu.RLock()
		defer server.mu.RUnlock()
		if server.natsConn == nil || server.natsConn == originalConn {
			return false
		}

		return server.natsConn.Status() == nats.CONNECTED
	}, 15*time.Second, 100*time.Millisecond, "event publisher did not reinitialize after connection close")

	publishCtx, cancelPublish := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelPublish()

	err := server.eventPublisher.PublishPollerOfflineEvent(publishCtx, "poller-1", "1.2.3.4", "default", time.Now())
	require.NoError(t, err, "expected publish to succeed after reinitialization")

	close(server.ShutdownChan)

	server.mu.RLock()
	currentConn := server.natsConn
	server.mu.RUnlock()
	if currentConn != nil {
		currentConn.Close()
	}
}

func runJetStreamServer(t *testing.T) *server.Server {
	t.Helper()

	opts := &server.Options{
		Host:      "127.0.0.1",
		Port:      -1,
		JetStream: true,
	}

	srv, err := server.NewServer(opts)
	require.NoError(t, err)

	go srv.Start()

	if !srv.ReadyForConnections(10 * time.Second) {
		srv.Shutdown()
		t.Fatalf("embedded NATS server not ready for connections")
	}

	require.Eventually(t, func() bool {
		return srv.JetStreamEnabled()
	}, 5*time.Second, 50*time.Millisecond, "embedded NATS server not ready for JetStream")

	return srv
}
