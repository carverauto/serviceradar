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

package cli

import (
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
)

// TestPartitionCoreACL_RuntimePublishSemantics is the B-7 runtime
// regression. The earlier shape of GeneratePartitionCoreCreds (and the
// matching rendered nats-server.conf / helm template) listed the
// unscoped wildcard "flow.attributed.>" on PublishDeny while listing
// "flow.attributed.<partition>" and "flow.attributed.<partition>.>"
// on PublishAllow. The accompanying comment claimed NATS evaluated
// "allow-then-deny per token", but NATS publish authorization is
// actually "any matching deny wins" — for any subject token that
// matches both the allow set and the deny set, the publish is
// rejected by the server. The previous shape therefore prevented the
// partition-core from publishing to its own partition subject, while
// the JWT-shape unit tests passed because they only asserted the
// strings present in the credential, not the runtime behavior.
//
// This test boots a real nats-server in-process (same helper pattern
// as go/pkg/trivysidecar/publisher_integration_test.go and
// go/pkg/datasvc/nats_reconnect_test.go), seeds it with a
// "core-alpha" identity whose Permissions mirror the post-B-7-fix
// shape produced by GeneratePartitionCoreCreds, and asserts that:
//
//  1. core-alpha CAN publish to flow.attributed.alpha.
//  2. core-alpha CAN publish to flow.attributed.alpha.sub.
//  3. core-alpha CANNOT publish to flow.attributed.beta — NATS
//     rejects it because the subject is not in PublishAllow.
//
// Gated behind testing.Short() consistent with the other in-repo
// embedded-NATS integration tests.
func TestPartitionCoreACL_RuntimePublishSemantics(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	// Build a server config whose authorization block reflects the
	// permissions returned by GeneratePartitionCoreCreds (post-B-7).
	// Using the static-user/password path keeps the test focused on
	// publish ACL semantics; the JWT-account resolver is exercised by
	// the unit tests above.
	corePassword := "alpha-core-secret"
	otherPassword := "beta-core-secret"

	corePerms := partitionCorePermissions("alpha")
	otherPerms := partitionCorePermissions("beta")

	opts := &server.Options{
		Host: "127.0.0.1",
		Port: -1,
		Users: []*server.User{
			{
				Username:    "core-alpha",
				Password:    corePassword,
				Permissions: corePerms,
			},
			{
				Username:    "core-beta",
				Password:    otherPassword,
				Permissions: otherPerms,
			},
		},
	}

	srv := runACLServer(t, opts)
	t.Cleanup(srv.Shutdown)

	// Track permission-violation async errors per connection so we
	// can assert that cross-partition publishes are actually rejected
	// by the server (NATS publishes are fire-and-forget at the
	// protocol level; the server signals violations via the async
	// error callback).
	var (
		coreErrs    permErrTracker
		coreErrChan = make(chan error, 16)
	)

	nc, err := nats.Connect(
		srv.ClientURL(),
		nats.UserInfo("core-alpha", corePassword),
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, e error) {
			coreErrs.record(e)
			select {
			case coreErrChan <- e:
			default:
			}
		}),
	)
	if err != nil {
		t.Fatalf("connect as core-alpha: %v", err)
	}
	t.Cleanup(func() { nc.Close() })

	// (1) Own-partition publish (exact subject token) must succeed.
	if err := nc.Publish("flow.attributed.alpha", []byte(`{"own":true}`)); err != nil {
		t.Fatalf("core-alpha publish flow.attributed.alpha: %v", err)
	}
	// (2) Own-partition publish (subtree) must succeed.
	if err := nc.Publish("flow.attributed.alpha.sub", []byte(`{"sub":true}`)); err != nil {
		t.Fatalf("core-alpha publish flow.attributed.alpha.sub: %v", err)
	}
	if err := nc.Flush(); err != nil {
		t.Fatalf("flush after own-partition publishes: %v", err)
	}
	// Give the server a brief moment to surface any async permission
	// error tied to the publishes above. There should be none.
	if waitForAsyncErr(coreErrChan, 200*time.Millisecond) {
		t.Fatalf("unexpected permission violation for own-partition publish: %v", coreErrs.snapshot())
	}

	// (3) Cross-partition publish must be rejected by the server.
	// NATS sends a -ERR 'Permissions Violation' on the protocol stream
	// which surfaces through the async error handler.
	if err := nc.Publish("flow.attributed.beta", []byte(`{"cross":true}`)); err != nil {
		// Some client/server versions surface the violation
		// synchronously; that is also a success signal for this
		// regression.
		if isPermErr(err) {
			return
		}
		t.Fatalf("publish to flow.attributed.beta returned unexpected error: %v", err)
	}
	if err := nc.Flush(); err != nil {
		// Flush may itself report the permission violation,
		// which is still the assertion we want to make.
		if isPermErr(err) {
			return
		}
		t.Fatalf("flush after cross-partition publish: %v", err)
	}

	if !waitForAsyncErr(coreErrChan, 2*time.Second) {
		t.Fatalf("expected permission violation for cross-partition publish (flow.attributed.beta); got none")
	}

	// Confirm the recorded error is actually a permissions violation
	// against the cross-partition subject — guards against an unrelated
	// async error masquerading as a pass.
	last := coreErrs.last()
	if last == nil || !isPermErr(last) {
		t.Fatalf("expected permissions violation error, got: %v", last)
	}
	if !strings.Contains(last.Error(), "flow.attributed.beta") {
		t.Fatalf("expected permission violation to reference flow.attributed.beta, got: %v", last)
	}
}

// partitionCorePermissions returns the static-user shape of the
// per-partition core publish/subscribe ACL. It MUST mirror the
// runtime shape produced by GeneratePartitionCoreCreds — if that
// function widens or narrows the publish set, update this helper
// (and the test will fail loudly if the new shape regresses B-7).
func partitionCorePermissions(partitionID string) *server.Permissions {
	attributed := "flow.attributed." + partitionID

	return &server.Permissions{
		Publish: &server.SubjectPermission{
			Allow: []string{
				attributed,
				attributed + ".>",
				"flow.raw.>",
				"logs.>",
				"events.>",
				"config.>",
				"$JS.API.>",
				"$JS.ACK.>",
				"_INBOX.>",
			},
			// B-7: $SYS.> ONLY. A "flow.attributed.>" wildcard deny
			// here would shadow the partition-scoped allows above.
			Deny: []string{"$SYS.>"},
		},
		Subscribe: &server.SubjectPermission{
			Allow: []string{
				"flow.host-slice.>",
				attributed,
				attributed + ".>",
				"flow.raw.>",
				"logs.>",
				"events.>",
				"config.>",
				"$JS.API.>",
				"$JS.ACK.>",
				"_INBOX.>",
			},
			Deny: []string{"$SYS.>"},
		},
	}
}

// runACLServer boots an embedded NATS server with the supplied
// options and waits for it to accept client connections. Same
// pattern as go/pkg/trivysidecar/publisher_integration_test.go
// (runJetStreamServer) and go/pkg/datasvc/nats_reconnect_test.go
// (runJetStreamServer), minus the JetStream readiness gate (not
// needed for pure publish-ACL tests).
func runACLServer(t *testing.T, opts *server.Options) *server.Server {
	t.Helper()

	srv, err := server.NewServer(opts)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	go srv.Start()

	if !srv.ReadyForConnections(10 * time.Second) {
		srv.Shutdown()
		t.Fatalf("embedded nats server not ready")
	}
	return srv
}

// permErrTracker captures async errors surfaced by the nats client
// for assertion. We need both "did any error arrive" and "what was
// the last error" to make the cross-partition publish assertion
// precise.
type permErrTracker struct {
	mu     sync.Mutex
	errs   []error
	hasAny atomic.Bool
}

func (p *permErrTracker) record(err error) {
	if err == nil {
		return
	}
	p.mu.Lock()
	p.errs = append(p.errs, err)
	p.mu.Unlock()
	p.hasAny.Store(true)
}

func (p *permErrTracker) last() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.errs) == 0 {
		return nil
	}
	return p.errs[len(p.errs)-1]
}

func (p *permErrTracker) snapshot() []error {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]error, len(p.errs))
	copy(out, p.errs)
	return out
}

func waitForAsyncErr(ch <-chan error, within time.Duration) bool {
	timer := time.NewTimer(within)
	defer timer.Stop()
	select {
	case <-ch:
		return true
	case <-timer.C:
		return false
	}
}

// isPermErr matches both nats.ErrPermissionViolation (newer clients)
// and the textual "Permissions Violation" surfaced by older clients
// or by the async error path. Keeping the match string-based avoids
// coupling the test to a specific nats.go internal type that may
// move between versions.
func isPermErr(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, nats.ErrPermissionViolation) {
		return true
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "permissions violation") ||
		strings.Contains(msg, "permission violation") ||
		strings.Contains(msg, "permissions denied") ||
		strings.Contains(msg, "not authorized")
}
