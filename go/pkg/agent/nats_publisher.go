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

// Package agent pkg/agent/nats_publisher.go
//
// flowPublisher owns the agent's authenticated NATS connection used to
// publish per-host flow slices on `flow.host-slice.<agent-id>` (B-5
// sub-issue 1). Credentials come from the edge-bundle bootstrap config
// (`nats_creds_file`) written by bundle_generator.ex/maybe_put_nats_creds
// and landed on disk by edgeonboarding.EnrollAgentFromToken.
package agent

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/natsutil"
)

// ErrFlowPublisherCredsMissing is returned when the configured
// nats_creds_file path does not exist on disk. We surface a clear error
// here instead of silently falling back to anonymous auth, which would
// defeat the purpose of B-5 (per-agent JWT-scoped publishing).
var ErrFlowPublisherCredsMissing = errors.New("nats_creds_file does not exist on disk")

// ErrFlowPublisherURLMissing is returned when nats_creds_file is set but
// nats_url is empty. This misconfiguration cannot be recovered from
// because we have no endpoint to authenticate against.
var ErrFlowPublisherURLMissing = errors.New("nats_creds_file set but nats_url is empty; cannot connect")

// flowPublisher wraps the NATS connection that publishes per-host flow
// slices. It is created lazily at agent startup and torn down with Stop.
type flowPublisher struct {
	mu     sync.Mutex
	conn   *nats.Conn
	url    string
	creds  string
	logger logger.Logger
}

// flowPublisherConfig groups the inputs required to bring up the
// publisher. It mirrors the canonical Go pattern used by db-event-writer
// and trivysidecar, but is gated on a non-empty creds path so the agent
// stays backwards-compatible with deployments that have not enrolled a
// flow-collector JWT.
type flowPublisherConfig struct {
	URL      string
	Creds    string
	Security *models.SecurityConfig
}

// connector abstracts the actual NATS dial so unit tests can verify the
// option list (in particular that nats.UserCredentials is appended)
// without standing up an embedded NATS server.
type natsConnector func(ctx context.Context, url string, security *models.SecurityConfig, extraOpts ...nats.Option) (*nats.Conn, error)

// defaultNATSConnector dials via the shared helper that already wires
// mTLS + reconnect handlers; UserCredentials is appended in
// buildExtraNATSOpts so it sits in the extraOpts slot of
// ConnectWithSecurity.
//
//nolint:gochecknoglobals,gocritic // injectable connector for test stubbing; thin wrapper around natsutil.ConnectWithSecurity is intentional so tests can replace the connector without monkey-patching natsutil
var defaultNATSConnector natsConnector = func(ctx context.Context, url string, security *models.SecurityConfig, extraOpts ...nats.Option) (*nats.Conn, error) {
	return natsutil.ConnectWithSecurity(ctx, url, security, extraOpts...)
}

// buildExtraNATSOpts assembles the per-connection nats.Option slice that
// is layered on top of natsutil.ConnectWithSecurity's TLS+handlers
// defaults. Today it adds nats.UserCredentials when a creds path is
// configured and verified to exist; it is split out so the unit test
// can assert the slot is populated without needing a live NATS server.
//
// Returns ErrFlowPublisherCredsMissing when credsFile is non-empty but
// the path does not exist (acceptance criterion #4).
func buildExtraNATSOpts(credsFile string) ([]nats.Option, error) {
	creds := strings.TrimSpace(credsFile)
	if creds == "" {
		return nil, nil
	}

	if _, err := os.Stat(creds); err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrFlowPublisherCredsMissing, creds)
		}
		return nil, fmt.Errorf("failed to stat nats_creds_file %q: %w", creds, err)
	}

	return []nats.Option{nats.UserCredentials(creds)}, nil
}

// newFlowPublisher constructs the publisher. It returns (nil, nil) when
// neither URL nor creds are configured, so callers can treat "no
// publisher" and "publisher off by config" identically. When the URL is
// configured but creds are not, we still dial (backwards-compatible
// fallback to existing auth — mTLS via security, or anonymous —
// acceptance criterion #3). When creds are configured but the file is
// missing, we fail loudly (acceptance criterion #4).
func newFlowPublisher(ctx context.Context, cfg flowPublisherConfig, log logger.Logger, connect natsConnector) (*flowPublisher, error) {
	url := strings.TrimSpace(cfg.URL)
	creds := strings.TrimSpace(cfg.Creds)

	// Both empty: feature disabled.
	if url == "" && creds == "" {
		return nil, nil
	}

	// Creds without URL is a misconfiguration we cannot recover from.
	if url == "" {
		return nil, ErrFlowPublisherURLMissing
	}

	extraOpts, err := buildExtraNATSOpts(creds)
	if err != nil {
		return nil, err
	}

	if connect == nil {
		connect = defaultNATSConnector
	}

	nc, err := connect(ctx, url, cfg.Security, extraOpts...)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS at %s: %w", url, err)
	}

	p := &flowPublisher{
		conn:   nc,
		url:    url,
		creds:  creds,
		logger: log,
	}

	log.Info().
		Str("nats_url", url).
		Bool("user_credentials", creds != "").
		Msg("Agent flow publisher connected to NATS")

	return p, nil
}

// Close drains and closes the underlying NATS connection. Safe to call
// multiple times.
func (p *flowPublisher) Close() {
	if p == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.conn == nil {
		return
	}

	if err := p.conn.Drain(); err != nil && p.logger != nil {
		p.logger.Warn().Err(err).Msg("Agent flow publisher drain returned error")
	}
	p.conn = nil
}

// Conn returns the underlying *nats.Conn for downstream publishers (the
// Phase-4 task 21.3 host-slice publisher). Returns nil when the
// publisher is not connected.
func (p *flowPublisher) Conn() *nats.Conn {
	if p == nil {
		return nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	return p.conn
}

// initFlowPublisher constructs the optional flow publisher. The
// no-config path (both NATSURL and NATSCredsFile empty) returns nil so
// agents without flow-collector enrollment continue to run. When the
// operator HAS expressed intent in config (either field non-empty) any
// error here — including ErrFlowPublisherCredsMissing or a dial
// failure — is propagated to the caller so the agent fails to start
// rather than silently falling back to anonymous auth. Silent fallback
// would defeat B-5 (per-agent JWT-scoped publishing); the
// caller (NewServer) enforces that policy via errors.Is +
// config-intent guards.
func (s *Server) initFlowPublisher(ctx context.Context) error {
	cfg := flowPublisherConfig{
		URL:      s.config.NATSURL,
		Creds:    s.config.NATSCredsFile,
		Security: s.config.NATSSecurity,
	}

	p, err := newFlowPublisher(ctx, cfg, s.logger, nil)
	if err != nil {
		return err
	}

	if p == nil {
		s.logger.Debug().Msg("Agent flow publisher disabled (no nats_url/nats_creds_file in config)")
		return nil
	}

	s.flowPublisher = p
	return nil
}
