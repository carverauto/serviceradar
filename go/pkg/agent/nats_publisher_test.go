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

package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const testNATSUserJWT = "stub-user-jwt"

// writeCredsFile writes a syntactically-valid minimal NATS .creds file
// (the contents are never parsed by nats.UserCredentials at config-bind
// time — it just records the path — so a placeholder is sufficient for
// these tests).
func writeCredsFile(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "nats.creds")
	const stub = `-----BEGIN NATS USER JWT-----
stub-user-jwt
------END NATS USER JWT------

-----BEGIN USER NKEY SEED-----
SUAEXAMPLE
------END USER NKEY SEED------
`
	require.NoError(t, os.WriteFile(path, []byte(stub), 0600))
	return path
}

func TestBuildExtraNATSOpts_EmptyReturnsNil(t *testing.T) {
	opts, err := buildExtraNATSOpts("")
	require.NoError(t, err)
	require.Nil(t, opts)

	opts, err = buildExtraNATSOpts("   ")
	require.NoError(t, err)
	require.Nil(t, opts)
}

func TestBuildExtraNATSOpts_MissingFileFailsClearly(t *testing.T) {
	// Acceptance criterion #4: a non-existent creds path must fail at
	// connect time with a clear error, NOT silently fall back to
	// anonymous auth.
	missing := filepath.Join(t.TempDir(), "does-not-exist.creds")

	opts, err := buildExtraNATSOpts(missing)
	require.Error(t, err)
	require.Nil(t, opts)
	require.True(t, errors.Is(err, ErrFlowPublisherCredsMissing),
		"expected ErrFlowPublisherCredsMissing, got %v", err)
	require.Contains(t, err.Error(), missing,
		"error message should mention the missing path for operator visibility")
}

func TestBuildExtraNATSOpts_AppendsUserCredentialsOption(t *testing.T) {
	// Acceptance criterion #2/#5: when nats_creds_file is set and the
	// file exists, an option that registers JWT + signature callbacks
	// must be appended and must resolve the JWT from the configured
	// .creds file. This catches regressions where a handler slot is
	// populated but points at the wrong credential source.
	path := writeCredsFile(t)

	opts, err := buildExtraNATSOpts(path)
	require.NoError(t, err)
	require.Len(t, opts, 1, "expected exactly one extra opt (UserCredentials)")

	var applied nats.Options
	require.NoError(t, opts[0](&applied))
	require.NotNil(t, applied.UserJWT,
		"nats.UserCredentials should register a UserJWT handler")
	require.NotNil(t, applied.SignatureCB,
		"nats.UserCredentials should register a SignatureCB handler")

	jwt, err := applied.UserJWT()
	require.NoError(t, err)
	require.Equal(t, testNATSUserJWT, jwt)
}

func TestNewFlowPublisher_DisabledWhenAllEmpty(t *testing.T) {
	// Acceptance criterion #3: with no NATS config, no connection is
	// attempted and no error is returned — the agent runs without it.
	log := logger.NewTestLogger()
	called := false
	connect := func(_ context.Context, _ string, _ *models.SecurityConfig, _ ...nats.Option) (*nats.Conn, error) {
		called = true
		return nil, nil
	}

	p, err := newFlowPublisher(context.Background(), flowPublisherConfig{}, log, connect)
	require.NoError(t, err)
	require.Nil(t, p)
	require.False(t, called, "connector must not be called when feature is disabled")
}

func TestNewFlowPublisher_CredsWithoutURLFails(t *testing.T) {
	log := logger.NewTestLogger()
	connect := func(_ context.Context, _ string, _ *models.SecurityConfig, _ ...nats.Option) (*nats.Conn, error) {
		t.Fatalf("connector should not be called when URL is missing")
		return nil, nil
	}

	p, err := newFlowPublisher(context.Background(), flowPublisherConfig{
		Creds: writeCredsFile(t),
	}, log, connect)
	require.Error(t, err)
	require.Nil(t, p)
	require.Contains(t, err.Error(), "nats_url")
}

func TestNewFlowPublisher_MissingCredsFileFails(t *testing.T) {
	// Acceptance criterion #4 at the publisher level: don't dial when
	// the creds path is invalid — surface the error to the caller.
	log := logger.NewTestLogger()
	missing := filepath.Join(t.TempDir(), "nope.creds")
	connect := func(_ context.Context, _ string, _ *models.SecurityConfig, _ ...nats.Option) (*nats.Conn, error) {
		t.Fatalf("connector should not be called when creds path is missing")
		return nil, nil
	}

	p, err := newFlowPublisher(context.Background(), flowPublisherConfig{
		URL:   "nats://127.0.0.1:4222",
		Creds: missing,
	}, log, connect)
	require.Error(t, err)
	require.Nil(t, p)
	require.True(t, errors.Is(err, ErrFlowPublisherCredsMissing))
}

func TestNewFlowPublisher_PassesUserCredentialsOption(t *testing.T) {
	// Acceptance criterion #5: when the bootstrap config has
	// nats_creds_file set, the connector receives a nats.Option that
	// installs UserCredentials against the configured creds file. This
	// is behavioral: the applied option must resolve the same JWT bytes
	// that were written to disk.
	log := logger.NewTestLogger()
	path := writeCredsFile(t)

	var capturedURL string
	var capturedSecurity *models.SecurityConfig
	var capturedExtras []nats.Option
	connect := func(_ context.Context, url string, security *models.SecurityConfig, extraOpts ...nats.Option) (*nats.Conn, error) {
		capturedURL = url
		capturedSecurity = security
		capturedExtras = extraOpts
		// Returning a nil *nats.Conn is fine — newFlowPublisher just
		// stores whatever the connector hands back; this test never
		// touches the connection.
		return nil, nil
	}

	p, err := newFlowPublisher(context.Background(), flowPublisherConfig{
		URL:   "nats://example:4222",
		Creds: path,
	}, log, connect)
	require.NoError(t, err)
	require.NotNil(t, p)
	require.Equal(t, "nats://example:4222", capturedURL)
	require.Nil(t, capturedSecurity)
	require.Len(t, capturedExtras, 1, "expected exactly one extra option (UserCredentials)")

	// Verify the captured option is the one produced by
	// nats.UserCredentials by applying it and inspecting the handlers.
	var applied nats.Options
	require.NoError(t, capturedExtras[0](&applied))
	require.NotNil(t, applied.UserJWT,
		"connector should receive the UserCredentials option (UserJWT handler)")
	require.NotNil(t, applied.SignatureCB,
		"connector should receive the UserCredentials option (SignatureCB handler)")

	jwt, err := applied.UserJWT()
	require.NoError(t, err)
	require.Equal(t, testNATSUserJWT, jwt)
}

func TestNewFlowPublisher_URLOnlyFallsBackToExistingAuth(t *testing.T) {
	// Acceptance criterion #3: nats_url set without nats_creds_file
	// stays backwards-compatible — connector is called WITHOUT a
	// UserCredentials option, so mTLS via security or anonymous auth
	// remain in play.
	log := logger.NewTestLogger()
	var capturedExtras []nats.Option
	connect := func(_ context.Context, _ string, _ *models.SecurityConfig, extraOpts ...nats.Option) (*nats.Conn, error) {
		capturedExtras = extraOpts
		return nil, nil
	}

	p, err := newFlowPublisher(context.Background(), flowPublisherConfig{
		URL: "nats://example:4222",
	}, log, connect)
	require.NoError(t, err)
	require.NotNil(t, p)
	require.Empty(t, capturedExtras,
		"no UserCredentials option should be appended when nats_creds_file is empty")
}

func TestNewFlowPublisher_ConnectorErrorPropagates(t *testing.T) {
	log := logger.NewTestLogger()
	wantErr := errors.New("dial refused")
	connect := func(_ context.Context, _ string, _ *models.SecurityConfig, _ ...nats.Option) (*nats.Conn, error) {
		return nil, wantErr
	}

	p, err := newFlowPublisher(context.Background(), flowPublisherConfig{
		URL: "nats://example:4222",
	}, log, connect)
	require.Error(t, err)
	require.Nil(t, p)
	require.ErrorIs(t, err, wantErr)
}

// TestInitFlowPublisher_MissingCredsFailLoud guards the server-level
// policy for Mi-97: when the operator explicitly configures
// nats_creds_file but the file does not exist, the publisher init must
// return ErrFlowPublisherCredsMissing and the caller (NewServer) must
// fail-loud rather than demoting to a log.Warn. Without this test the
// demotion regression (server.go swallowing the sentinel) is invisible
// to CI. See nats_publisher.go ErrFlowPublisherCredsMissing godoc and
// server.go NewServer flow-publisher init branch.
func TestInitFlowPublisher_MissingCredsFailLoud(t *testing.T) {
	t.Parallel()

	missing := filepath.Join(t.TempDir(), "absent.creds")
	s := &Server{
		config: &ServerConfig{
			AgentID:       "test-agent",
			NATSURL:       "nats://example:4222",
			NATSCredsFile: missing,
		},
		logger: logger.NewTestLogger(),
	}

	err := s.initFlowPublisher(context.Background())
	require.Error(t, err)
	require.True(t, errors.Is(err, ErrFlowPublisherCredsMissing),
		"expected ErrFlowPublisherCredsMissing to propagate from initFlowPublisher, got %v", err)
	require.Nil(t, s.flowPublisher,
		"flowPublisher must remain nil when initialization fails so the agent cannot publish unauthenticated")
}

// TestInitFlowPublisher_NoConfigIsNoOp guards the backwards-compatible
// path required by acceptance criterion #2: when neither NATSURL nor
// NATSCredsFile is set, initFlowPublisher returns nil and the caller
// proceeds without a publisher.
func TestInitFlowPublisher_NoConfigIsNoOp(t *testing.T) {
	t.Parallel()

	s := &Server{
		config: &ServerConfig{
			AgentID: "test-agent",
		},
		logger: logger.NewTestLogger(),
	}

	require.NoError(t, s.initFlowPublisher(context.Background()))
	require.Nil(t, s.flowPublisher,
		"no-config path must leave flowPublisher unset")
}

// TestInitFlowPublisher_CredsWithoutURLFailLoud guards the
// misconfiguration path at the publisher level — operator set
// nats_creds_file but forgot nats_url. This case is intent-bearing
// (creds non-empty) and must surface to the caller.
func TestInitFlowPublisher_CredsWithoutURLFailLoud(t *testing.T) {
	t.Parallel()

	s := &Server{
		config: &ServerConfig{
			AgentID:       "test-agent",
			NATSCredsFile: writeCredsFile(t),
		},
		logger: logger.NewTestLogger(),
	}

	err := s.initFlowPublisher(context.Background())
	require.Error(t, err)
	require.Contains(t, err.Error(), "nats_url",
		"creds-without-URL misconfiguration must surface a clear nats_url error")
	require.Nil(t, s.flowPublisher)
}
