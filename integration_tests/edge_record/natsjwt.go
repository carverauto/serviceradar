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
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nkeys"
)

// natsjwt.go boots a real, embedded, JetStream-enabled nats-server with a
// minimal decentralized JWT trust chain (one operator, one account, one
// user), because both AGENT_GATEWAY_NATS_CREDS_FILE
// (elixir/serviceradar_agent_gateway/config/runtime.exs:446) and
// EVENT_WRITER_NATS_CREDS_FILE
// (elixir/serviceradar_core/config/runtime.exs:1646-1654, which RAISES at
// boot when EVENT_WRITER_ENABLED=true and no creds file is set) require a
// real .creds file, not a bare unauthenticated connection.
//
// Deliberately bypasses go/pkg/nats/accounts (the production account
// provisioning tool): NewAccountSigner's default subject mappings
// (go/pkg/nats/accounts/account_manager.go's defaultSubjectMappings, e.g.
// "telemetry.>" -> "{{namespace}}.telemetry.>") exist for the multi-tenant
// partition model and would silently remap the real edge-record subject
// telemetry.edge-record.v1.bulk.> (elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex:478)
// into a namespaced subject nothing in this single-account test harness
// expects. Building the operator/account/user JWTs directly with nkeys +
// jwt/v2 (both already production dependencies, go.mod) keeps this account
// a flat, unmapped, full-access single tenant.

const (
	jetStreamMemoryBytes    int64 = 512 * 1024 * 1024
	jetStreamDiskBytes      int64 = 2 * 1024 * 1024 * 1024
	jetStreamStreamLimit    int64 = 64
	jetStreamConsumerLimit  int64 = 64
	jetStreamMaxAckPending  int64 = 1_000_000
	jetStreamMemoryMaxBytes int64 = 512 * 1024 * 1024
	jetStreamDiskMaxBytes   int64 = 2 * 1024 * 1024 * 1024
)

// NATSHarness is one embedded, JetStream-enabled nats-server instance with a
// minimal single-account JWT trust chain (full ">" publish/subscribe
// permissions, no subject remapping), satisfying both
// AGENT_GATEWAY_NATS_CREDS_FILE and EVENT_WRITER_NATS_CREDS_FILE's
// creds-file requirement.
type NATSHarness struct {
	Server    *server.Server
	URL       string
	CredsPath string
}

// StartEmbeddedNATS boots the server with JetStream storage under storeDir
// and writes the user .creds file under credsDir. Both directories are
// created if needed.
func StartEmbeddedNATS(storeDir, credsDir string) (*NATSHarness, error) {
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		return nil, fmt.Errorf("verticalslice: mkdir nats store dir: %w", err)
	}
	if err := os.MkdirAll(credsDir, 0o700); err != nil {
		return nil, fmt.Errorf("verticalslice: mkdir nats creds dir: %w", err)
	}

	operatorKP, err := nkeys.CreateOperator()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create operator key: %w", err)
	}
	operatorPub, err := operatorKP.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: operator public key: %w", err)
	}

	// A separate, JetStream-less system account is required: nats-server
	// refuses to enable JetStream on the system account itself ("Not allowed
	// to enable JetStream on the system account"). The working account below
	// is what the gateway/core releases actually authenticate as.
	sysAccountKP, err := nkeys.CreateAccount()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create system account key: %w", err)
	}
	sysAccountPub, err := sysAccountKP.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: system account public key: %w", err)
	}

	sysAccountClaims := jwt.NewAccountClaims(sysAccountPub)
	sysAccountClaims.Name = "vertical-slice-sys"
	sysAccountClaims.Issuer = operatorPub

	sysAccountJWT, err := sysAccountClaims.Encode(operatorKP)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: sign system account JWT: %w", err)
	}

	accountKP, err := nkeys.CreateAccount()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create account key: %w", err)
	}
	accountPub, err := accountKP.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: account public key: %w", err)
	}

	accountClaims := jwt.NewAccountClaims(accountPub)
	accountClaims.Name = "vertical-slice"
	accountClaims.Issuer = operatorPub
	// Full, unmapped access: no Exports/Imports/Mappings, matching a flat
	// single-tenant test account rather than the production partition model.
	accountClaims.Limits.JetStreamLimits = jwt.JetStreamLimits{
		MemoryStorage:        jetStreamMemoryBytes,
		DiskStorage:          jetStreamDiskBytes,
		Streams:              jetStreamStreamLimit,
		Consumer:             jetStreamConsumerLimit,
		MaxAckPending:        jetStreamMaxAckPending,
		MemoryMaxStreamBytes: jetStreamMemoryMaxBytes,
		DiskMaxStreamBytes:   jetStreamDiskMaxBytes,
		MaxBytesRequired:     false,
	}

	accountJWT, err := accountClaims.Encode(operatorKP)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: sign account JWT: %w", err)
	}

	operatorClaims := jwt.NewOperatorClaims(operatorPub)
	operatorClaims.Name = "vertical-slice-operator"
	operatorClaims.SystemAccount = sysAccountPub

	operatorJWT, err := operatorClaims.Encode(operatorKP)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: sign operator JWT: %w", err)
	}
	// Decode back into the *jwt.OperatorClaims shape server.Options.TrustedOperators
	// expects (the signed token, not the pre-signed builder).
	decodedOperatorClaims, err := jwt.DecodeOperatorClaims(operatorJWT)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: decode operator JWT: %w", err)
	}

	userKP, err := nkeys.CreateUser()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create user key: %w", err)
	}
	userPub, err := userKP.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: user public key: %w", err)
	}

	userClaims := jwt.NewUserClaims(userPub)
	userClaims.Name = "vertical-slice-user"
	userClaims.Issuer = accountPub
	// No Pub/Sub Allow/Deny set: an unrestricted user under this single
	// full-access account.

	userJWT, err := userClaims.Encode(accountKP)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: sign user JWT: %w", err)
	}

	userSeed, err := userKP.Seed()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: user seed: %w", err)
	}

	credsPath := filepath.Join(credsDir, "vertical-slice.creds")
	if err := os.WriteFile(credsPath, []byte(formatCredsFile(userJWT, userSeed)), 0o600); err != nil {
		return nil, fmt.Errorf("verticalslice: write creds file: %w", err)
	}

	resolver := &server.MemAccResolver{}
	if err := resolver.Store(accountPub, accountJWT); err != nil {
		return nil, fmt.Errorf("verticalslice: preload account JWT: %w", err)
	}
	if err := resolver.Store(sysAccountPub, sysAccountJWT); err != nil {
		return nil, fmt.Errorf("verticalslice: preload system account JWT: %w", err)
	}

	opts := &server.Options{
		Host:             "127.0.0.1",
		Port:             -1, // random free port
		JetStream:        true,
		StoreDir:         storeDir,
		TrustedOperators: []*jwt.OperatorClaims{decodedOperatorClaims},
		AccountResolver:  resolver,
		SystemAccount:    sysAccountPub,
		NoLog:            true,
		NoSigs:           true,
	}

	srv, err := server.NewServer(opts)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: new nats server: %w", err)
	}

	srv.ConfigureLogger()
	go srv.Start()

	if !srv.ReadyForConnections(15 * time.Second) {
		srv.Shutdown()
		return nil, fmt.Errorf("verticalslice: embedded nats server not ready")
	}

	return &NATSHarness{
		Server:    srv,
		URL:       srv.ClientURL(),
		CredsPath: credsPath,
	}, nil
}

// Shutdown stops the embedded server.
func (h *NATSHarness) Shutdown() {
	if h == nil || h.Server == nil {
		return
	}
	h.Server.Shutdown()
	h.Server.WaitForShutdown()
}

// formatCredsFile renders the standard nsc-compatible .creds format: two
// PEM-like blocks nats.go's nats.UserCredentials(path) parses by looking for
// the BEGIN/END marker lines verbatim.
func formatCredsFile(userJWT string, userSeed []byte) string {
	return fmt.Sprintf(`-----BEGIN NATS USER JWT-----
%s
------END NATS USER JWT------

************************* IMPORTANT *************************
NKEY Seed printed below can be used to sign and prove identity.
NKEYs are sensitive and should be treated as secrets.

-----BEGIN USER NKEY SEED-----
%s
------END USER NKEY SEED------

*************************************************************
`, userJWT, string(userSeed))
}
