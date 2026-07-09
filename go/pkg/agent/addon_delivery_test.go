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
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testOldConfigVersion = "old-version"
	testNewConfigVersion = "new-version"
)

// Static test errors (err113: tests must not construct dynamic errors inline).
var (
	errTestPermanentDelivery = errors.New("boom")
	errTestTransientDelivery = errors.New("dial tcp: connection refused")
)

// newDeliveryTestPushLoop builds a PushLoop with a real (temp-dir) add-on manager and a
// logger, suitable for exercising applyConfigResponse/applyAddonAssignments end to end.
func newDeliveryTestPushLoop(t *testing.T) *PushLoop {
	t.Helper()

	server := &Server{
		config: &ServerConfig{AgentID: "agent-test"},
		addonManager: agentaddon.NewManager(agentaddon.Config{
			RuntimeDir: filepath.Join(t.TempDir(), "addons"),
		}),
	}

	pl := NewPushLoop(server, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	return pl
}

// statusServer returns an httptest server that always responds with the given HTTP status.
func statusServer(t *testing.T, status int) (*httptest.Server, *int64) {
	t.Helper()

	var hits int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt64(&hits, 1)
		w.WriteHeader(status)
	}))
	t.Cleanup(srv.Close)

	return srv, &hits
}

func sidecar404Assignment(addonID, downloadURL string) *proto.AddonAssignmentConfig {
	return &proto.AddonAssignmentConfig{
		AddonId:           addonID,
		Enabled:           true,
		Version:           "1.0.0",
		Delivery:          addonDeliveryPushedArtifact,
		Supervision:       addonSupervisionAgentSidecar,
		ArtifactObjectKey: "native-addons/" + addonID + "/1.0.0/linux/amd64/addon.tar.gz",
		ArtifactSha256:    sha256Hex([]byte("artifact-bytes")),
		BinaryPath:        "/var/lib/serviceradar/agent/addons/" + addonID + "/current/serviceradar-" + addonID,
		DownloadUrl:       downloadURL,
		DownloadToken:     "tok",
	}
}

// A permanent (404) add-on artifact delivery failure must NOT wedge the config-version
// ack — the live ns05 bug. The agent records the failure and acks the version so every
// other config section stops being re-applied every poll.
func TestApplyConfigResponseAcksVersionWhenAddonDownload404s(t *testing.T) {
	srv, hits := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)
	pl.setConfigVersion(testOldConfigVersion)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons:        []*proto.AddonAssignmentConfig{sidecar404Assignment("netprobe", srv.URL)},
	}, "poll")

	if !ok {
		t.Fatal("applyConfigResponse() = false, want true: a permanent 404 must not block the ack")
	}
	if got := pl.getConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("config version = %q, want %s (the ack must proceed)", got, testNewConfigVersion)
	}
	if atomic.LoadInt64(hits) == 0 {
		t.Fatal("expected the gateway artifact endpoint to be hit at least once")
	}

	// The failure is recorded so it can be surfaced as per-add-on status.
	failures := pl.addonDeliveryFailureSnapshot()
	if _, ok := failures["netprobe"]; !ok {
		t.Fatalf("expected a recorded delivery failure for netprobe, got %v", failures)
	}
}

// A permanent 404 add-on failure surfaces as an unhealthy `addon:<id>` status entry so the
// control plane shows the failure instead of the add-on silently vanishing.
func TestAddonDeliveryFailureSurfacesAsStatus(t *testing.T) {
	srv, _ := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)

	// A permanent 404 must NOT block the config ack: applyAddonAssignments reports a
	// permanent (non-deferring) disposition while recording the failure for status
	// surfacing, so the section is visible on the ack without wedging the version.
	disposition, err := pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{
		sidecar404Assignment("netprobe", srv.URL),
	})
	if disposition != addonDeliveryPermanentFailure || err == nil {
		t.Fatalf("applyAddonAssignments() = %v (%v), want a reported permanent failure that does not defer the ack", disposition, err)
	}
	if _, ok := pl.addonDeliveryFailureSnapshot()["netprobe"]; !ok {
		t.Fatal("expected a recorded delivery failure for netprobe")
	}
}

// The status helper emits an unhealthy entry carrying the failure reason.
func TestAddonDeliveryFailureStatusesEmitsUnhealthy(t *testing.T) {
	srv, _ := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)

	_, _ = pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{
		sidecar404Assignment("rdp", srv.URL),
	})

	statuses := pl.addonDeliveryFailureStatuses(nil)
	if len(statuses) != 1 {
		t.Fatalf("expected 1 delivery-failure status, got %d (%v)", len(statuses), statuses)
	}
	if statuses[0].GetName() != "addon:rdp" {
		t.Fatalf("status name = %q, want addon:rdp", statuses[0].GetName())
	}
	if statuses[0].GetState() != string(agentaddon.StateUnhealthy) {
		t.Fatalf("status state = %q, want %s", statuses[0].GetState(), agentaddon.StateUnhealthy)
	}
	if statuses[0].GetLastError() == "" {
		t.Fatal("expected the failure reason in last_error")
	}

	// An add-on with a real status entry already present is not duplicated as a failure.
	existing := []*proto.SidecarStatus{{Name: "addon:rdp", State: string(agentaddon.StateRunning)}}
	if got := pl.addonDeliveryFailureStatuses(existing); len(got) != 0 {
		t.Fatalf("expected no failure status when a real status exists, got %v", got)
	}
}

// Backoff: a permanently-404ing artifact is not re-downloaded on every poll. The same
// (addon, version, sha, config) is hit once, then suppressed inside the backoff window.
func TestAddonDeliveryBackoffSuppressesRapidRedownload(t *testing.T) {
	srv, hits := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)
	assignment := sidecar404Assignment("netprobe", srv.URL)

	// First poll: hits the gateway, records the permanent failure.
	_, _ = pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{assignment})
	afterFirst := atomic.LoadInt64(hits)
	if afterFirst == 0 {
		t.Fatal("expected the first poll to hit the gateway")
	}

	// Several more polls inside the backoff window must NOT re-download.
	for i := 0; i < 5; i++ {
		_, _ = pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{assignment})
	}
	if got := atomic.LoadInt64(hits); got != afterFirst {
		t.Fatalf("gateway hits = %d, want %d: backoff must suppress re-download of the same broken artifact", got, afterFirst)
	}

	// Every poll still acked the config (a permanent disposition never defers).
	if disposition, _ := pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{assignment}); disposition == addonDeliveryTransientFailure {
		t.Fatal("a backed-off permanent failure must still let the ack proceed")
	}
}

// A changed assignment (new version / sha / config) resets the backoff and is retried
// immediately — the operator re-pushing the add-on must not be throttled.
func TestAddonDeliveryBackoffResetsOnAssignmentChange(t *testing.T) {
	srv, hits := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)

	v1 := sidecar404Assignment("netprobe", srv.URL)
	_, _ = pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{v1})
	afterV1 := atomic.LoadInt64(hits)

	// Inside the backoff window but with a NEW version+sha: must retry (hit the gateway).
	v2 := sidecar404Assignment("netprobe", srv.URL)
	v2.Version = "1.0.1"
	v2.ArtifactSha256 = sha256Hex([]byte("different-artifact-bytes"))
	_, _ = pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{v2})

	if got := atomic.LoadInt64(hits); got <= afterV1 {
		t.Fatalf("gateway hits = %d, want > %d: a changed assignment must reset backoff", got, afterV1)
	}
}

// Recovery: once the backoff window elapses, the next reconcile re-attempts delivery (it
// must not permanently give up), so an artifact that later becomes available installs.
func TestAddonDeliveryRetriesAfterBackoffWindow(t *testing.T) {
	srv, hits := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)
	assignment := sidecar404Assignment("netprobe", srv.URL)

	now := time.Now()
	// First attempt fails permanently (404) and is recorded at `now`.
	if _, disp, err := pl.deliverAddonArtifact(context.Background(), assignment, addonDeliveryPushedArtifact, now); disp != addonDeliveryPermanentFailure || err == nil {
		t.Fatalf("first attempt disposition=%d err=%v, want permanent failure", disp, err)
	}
	afterFirst := atomic.LoadInt64(hits)

	// Still inside the window: suppressed (no new hit).
	if _, _, err := pl.deliverAddonArtifact(context.Background(), assignment, addonDeliveryPushedArtifact, now.Add(time.Minute)); !errors.Is(err, errAddonDeliveryBackoff) {
		t.Fatalf("within window err=%v, want errAddonDeliveryBackoff", err)
	}
	if got := atomic.LoadInt64(hits); got != afterFirst {
		t.Fatalf("gateway hits = %d, want %d (suppressed within backoff)", got, afterFirst)
	}

	// Past the window: the artifact is re-fetched (proving the agent did not give up). It
	// still 404s here, but the gateway IS hit again, so a now-available object would install.
	if _, _, err := pl.deliverAddonArtifact(context.Background(), assignment, addonDeliveryPushedArtifact, now.Add(addonDeliveryFailureBackoff+time.Second)); errors.Is(err, errAddonDeliveryBackoff) {
		t.Fatal("past the backoff window the delivery must be retried, not suppressed")
	}
	if got := atomic.LoadInt64(hits); got <= afterFirst {
		t.Fatalf("gateway hits = %d, want > %d: a retry past the window must re-fetch the artifact", got, afterFirst)
	}
}

// A successful delivery clears any recorded failure (so a later failure is reported fresh
// and not suppressed by a stale backoff).
func TestAddonDeliverySuccessClearsRecordedFailure(t *testing.T) {
	pl := newDeliveryTestPushLoop(t)
	a := &proto.AddonAssignmentConfig{AddonId: "compiled", Version: "1.0.0"}

	// Seed a recorded failure outside the backoff window, then a delivery with no
	// artifact reference (nothing to stage -> success) must clear it (and not be
	// suppressed, since we are past the backoff window).
	pl.recordAddonDeliveryFailure(a, errTestPermanentDelivery, time.Now().Add(-addonDeliveryFailureBackoff-time.Minute))
	if _, disp, err := pl.deliverAddonArtifact(context.Background(), a, "compiled_in", time.Now()); err != nil || disp != addonDeliverySucceeded {
		t.Fatalf("deliver disp=%d err=%v, want success (no artifact to stage)", disp, err)
	}
	if failures := pl.addonDeliveryFailureSnapshot(); len(failures) != 0 {
		t.Fatalf("expected the recorded failure to be cleared on success, got %v", failures)
	}
}

// A TRANSIENT failure (5xx gateway response) defers the ack so delivery is retried
// promptly, and is NOT backed off.
func TestApplyConfigResponseDefersAndDoesNotBackoffOnTransient5xx(t *testing.T) {
	srv, hits := statusServer(t, http.StatusBadGateway)
	pl := newDeliveryTestPushLoop(t)
	pl.setConfigVersion(testOldConfigVersion)
	assignment := sidecar404Assignment("netprobe", srv.URL)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons:        []*proto.AddonAssignmentConfig{assignment},
	}, "poll")

	if ok {
		t.Fatal("applyConfigResponse() = true, want false: a transient 5xx must defer the ack")
	}
	if got := pl.getConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("config version = %q, want %s (deferred)", got, testOldConfigVersion)
	}
	// A transient failure is not recorded as a permanent failure...
	if failures := pl.addonDeliveryFailureSnapshot(); len(failures) != 0 {
		t.Fatalf("transient failure must not be recorded as permanent, got %v", failures)
	}
	// ...and is not backed off, so the next poll retries immediately.
	afterFirst := atomic.LoadInt64(hits)
	_, _ = pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{assignment})
	if got := atomic.LoadInt64(hits); got <= afterFirst {
		t.Fatalf("gateway hits = %d, want > %d: a transient failure must not be backed off", got, afterFirst)
	}
}

func TestClassifyAddonDeliveryError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want addonDeliveryDisposition
	}{
		{"nil", nil, addonDeliverySucceeded},
		{"incomplete", ErrAddonArtifactIncomplete, addonDeliveryPermanentFailure},
		{"hash mismatch", ErrAddonArtifactHashMismatch, addonDeliveryPermanentFailure},
		{"signature invalid", ErrAddonSignatureInvalid, addonDeliveryPermanentFailure},
		{"unsafe path", ErrAddonUnsafePath, addonDeliveryPermanentFailure},
		{"tarball unsafe", ErrAddonTarballUnsafe, addonDeliveryPermanentFailure},
		{"tarball too large", ErrAddonTarballTooLarge, addonDeliveryPermanentFailure},
		{"tarball binary missing", ErrAddonTarballBinaryMissing, addonDeliveryPermanentFailure},
		{"runtime config ambiguous", ErrAddonRuntimeConfigAmbiguous, addonDeliveryPermanentFailure},
		{"object store unavailable", ErrAddonObjectStoreUnavailable, addonDeliveryTransientFailure},
		{
			"download 404",
			&gatewayArtifactStatusError{sentinel: ErrAddonArtifactDownloadFailed, statusCode: http.StatusNotFound},
			addonDeliveryPermanentFailure,
		},
		{
			"download 403",
			&gatewayArtifactStatusError{sentinel: ErrAddonArtifactDownloadFailed, statusCode: http.StatusForbidden},
			addonDeliveryPermanentFailure,
		},
		{
			"download 502",
			&gatewayArtifactStatusError{sentinel: ErrAddonArtifactDownloadFailed, statusCode: http.StatusBadGateway},
			addonDeliveryTransientFailure,
		},
		{
			"download 500",
			&gatewayArtifactStatusError{sentinel: ErrAddonArtifactDownloadFailed, statusCode: http.StatusInternalServerError},
			addonDeliveryTransientFailure,
		},
		{"download no status", ErrAddonArtifactDownloadFailed, addonDeliveryTransientFailure},
		{"wrapped 404", fmt.Errorf("download addon artifact via gateway: %w", &gatewayArtifactStatusError{sentinel: ErrAddonArtifactDownloadFailed, statusCode: http.StatusNotFound}), addonDeliveryPermanentFailure},
		{"connectivity", errTestTransientDelivery, addonDeliveryTransientFailure},
		{"context canceled", context.Canceled, addonDeliveryTransientFailure},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyAddonDeliveryError(tc.err); got != tc.want {
				t.Fatalf("classifyAddonDeliveryError(%v) = %d, want %d", tc.err, got, tc.want)
			}
		})
	}
}

// The gateway status error keeps errors.Is matching its sentinel while exposing the code.
func TestGatewayArtifactStatusErrorUnwrap(t *testing.T) {
	err := &gatewayArtifactStatusError{sentinel: ErrAddonArtifactDownloadFailed, statusCode: http.StatusNotFound}
	if !errors.Is(err, ErrAddonArtifactDownloadFailed) {
		t.Fatal("expected errors.Is to match the wrapped sentinel")
	}
	code, ok := gatewayArtifactStatusCode(err)
	if !ok || code != http.StatusNotFound {
		t.Fatalf("gatewayArtifactStatusCode = (%d, %v), want (404, true)", code, ok)
	}
}
