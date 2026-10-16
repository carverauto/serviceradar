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
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	agentgateway "github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	goproto "google.golang.org/protobuf/proto"
)

var errTestSectionBoom = errors.New("section boom")

// testNetprobeAddonStatusName is the AddonStatus entry name of the netprobe add-on.
const testNetprobeAddonStatusName = "addon:" + testNetprobeAddonID

// icmpCheckCount reports how many ICMP checks the config apply installed — the
// observable proof that the check section (which runs AFTER the add-on and visibility
// sections) was still evaluated in the same cycle.
func icmpCheckCount(pl *PushLoop) int {
	pl.icmpMu.RLock()
	defer pl.icmpMu.RUnlock()

	return len(pl.icmpChecks)
}

func testICMPCheck() *proto.AgentCheckConfig {
	return &proto.AgentCheckConfig{
		CheckId:     "check-1",
		CheckType:   "icmp",
		Name:        "ping core",
		Target:      "192.0.2.10",
		Enabled:     true,
		IntervalSec: 30,
		TimeoutSec:  5,
	}
}

func TestApplyConfigResponseMissingPluginSectionRevokesPriorAssignmentsBeforeAck(t *testing.T) {
	tests := []struct {
		name       string
		configJSON []byte
	}{
		{name: "plugin section omitted", configJSON: []byte(`{}`)},
		{name: "legacy JSON malformed", configJSON: []byte(`{"plugins":`)},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			manager := newTestPluginManager(t)
			assignment := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())

			manager.mu.Lock()
			manager.streams[assignment.AssignmentID] = assignment
			manager.mu.Unlock()

			runCtx, executionID, err := manager.registerStreamingExecution(t.Context(), assignment)
			if err != nil {
				t.Fatalf("register streaming execution: %v", err)
			}
			defer manager.unregisterStreamingExecution(executionID)

			loop := NewPushLoop(&Server{
				config:        &ServerConfig{AgentID: "agent-plugin-downgrade"},
				pluginManager: manager,
			}, nil, 30*time.Second, logger.NewTestLogger())
			loop.setConfigVersion("cfg-with-plugin")

			if !loop.applyConfigResponse(t.Context(), &proto.AgentConfigResponse{
				ConfigVersion: "cfg-without-plugin",
				ConfigJson:    tt.configJSON,
			}, "control") {
				t.Fatal("full config response was not committed")
			}

			select {
			case <-runCtx.Done():
			case <-time.After(time.Second):
				t.Fatal("removed plugin assignment did not cancel its active streaming execution")
			}

			manager.mu.RLock()
			remainingStreams := len(manager.streams)
			manager.mu.RUnlock()
			if remainingStreams != 0 {
				t.Fatalf("remaining plugin streams = %d, want 0", remainingStreams)
			}
			if got := loop.getConfigVersion(); got != "cfg-without-plugin" {
				t.Fatalf("committed config version = %q, want cfg-without-plugin", got)
			}
			if proofs := loop.buildConfigAck("cfg-without-plugin").GetAppliedPluginAssignments(); len(proofs) != 0 {
				t.Fatalf("config ack retained revoked assignment proofs: %#v", proofs)
			}
		})
	}
}

// Incident shape 1 (Bumblebee wedge, weeks of `Deferring config version update because
// Bumblebee config did not apply`): a TRANSIENT Bumblebee failure must defer the version
// commit so delivery retries — but the remaining sections in the same cycle must still
// be evaluated and applied.
func TestApplyConfigResponseBumblebeeTransientDefersWithoutSkippingLaterSections(t *testing.T) {
	dir := t.TempDir()
	pl := NewPushLoop(&Server{
		config: &ServerConfig{
			AgentID: "agent-1",
			Bumblebee: &BumblebeeStatusConfig{
				CatalogPath: filepath.Join(dir, "catalog", "current"),
				ProfilePath: filepath.Join(dir, "profile", "runtime.json"),
				TmpDir:      filepath.Join(dir, "tmp"),
			},
		},
	}, nil, 30*time.Second, logger.NewTestLogger())
	pl.setConfigVersion(testOldConfigVersion)

	// Enabled Bumblebee with a catalog but no object store: transient
	// (ErrCatalogObjectStoreUnavailable) — the incident's permission-denied class.
	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		BumblebeeConfig: &proto.BumblebeeConfig{
			Enabled: true,
			Catalog: &proto.BumblebeeCatalogAssignment{
				SnapshotRef: "snapshot-1",
				ObjectKey:   "bumblebee/catalogs/snapshot-1/catalog.json",
				Sha256:      strings.Repeat("0", 64),
			},
		},
		Checks: []*proto.AgentCheckConfig{testICMPCheck()},
	}, "poll")

	if ok {
		t.Fatal("applyConfigResponse() = true, want false: a transient Bumblebee failure must defer the version")
	}
	if got := pl.getConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("config version = %q, want %s (transient failures defer the commit)", got, testOldConfigVersion)
	}
	if got := icmpCheckCount(pl); got != 1 {
		t.Fatalf("icmp checks applied = %d, want 1: later sections must still apply in the same cycle", got)
	}
	// One transient attempt is recorded as transient (reported on the hello) and stays
	// below the escalation bound, so it defers rather than committing.
	failure, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]
	if !ok || failure.disposition != addonDeliveryTransientFailure || failure.attempts != 1 {
		t.Fatalf("bumblebee failure = %+v (recorded=%v), want one transient attempt", failure, ok)
	}
}

// A transient add-on assignment failure (5xx artifact download) used to EARLY-RETURN and
// skip the sysmon/plugin/visibility/check sections for the cycle. It must now defer the
// version while the remaining sections still apply.
func TestApplyConfigResponseTransientAddonFailureStillAppliesLaterSections(t *testing.T) {
	srv, hits := statusServer(t, http.StatusInternalServerError)
	pl := newDeliveryTestPushLoop(t)
	pl.setConfigVersion(testOldConfigVersion)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons:        []*proto.AddonAssignmentConfig{sidecar404Assignment("netprobe", srv.URL)},
		Checks:        []*proto.AgentCheckConfig{testICMPCheck()},
	}, "poll")

	if ok {
		t.Fatal("applyConfigResponse() = true, want false: a transient add-on failure must defer the version")
	}
	if got := pl.getConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("config version = %q, want %s (deferred)", got, testOldConfigVersion)
	}
	if *hits == 0 {
		t.Fatal("expected the artifact endpoint to be hit")
	}
	if got := icmpCheckCount(pl); got != 1 {
		t.Fatalf("icmp checks applied = %d, want 1: the check section must not be skipped by an add-on defer", got)
	}
	// The heavy idempotent pass completed, so a resend of the same version skips it.
	if got := pl.getLastAttemptedConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("last attempted version = %q, want %s", got, testNewConfigVersion)
	}
}

// Incident shape 2 (netprobe flow-attribution outage): a PERMANENT visibility failure
// (type-invalid netprobe add-on config_json) must NOT wedge the config apply — the
// version commits and acks, the failing section is reported on the ack with its error
// verbatim, and the netprobe add-on reads unhealthy instead of healthy/running.
func TestApplyConfigResponseNetprobeParseErrorCommitsAndReportsSection(t *testing.T) {
	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	manager := &recordingSidecarLifecycleManager{}
	pl := NewPushLoop(&Server{
		config:          &ServerConfig{AgentID: "agent-1"},
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  manager,
		sidecarStatus:   manager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)
	pl.setConfigVersion(testOldConfigVersion)

	// A corrupt row that still exceeds the decoder's bounded compatibility:
	// capture_interfaces must be an array, scalar string, or null.
	badNetprobe := &proto.AddonAssignmentConfig{
		AddonId:     agentnetprobe.DefaultSidecarName,
		Enabled:     true,
		Supervision: addonSupervisionSystemdService,
		ConfigJson:  []byte(`{"capture_interfaces": 42}`),
	}

	resp := &proto.AgentConfigResponse{
		ConfigVersion:    testNewConfigVersion,
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
		Addons:           []*proto.AddonAssignmentConfig{badNetprobe},
		Checks:           []*proto.AgentCheckConfig{testICMPCheck()},
	}

	if !pl.applyConfigResponse(context.Background(), resp, "control") {
		t.Fatal("applyConfigResponse() = false, want true: a permanent section failure must not defer the version")
	}
	if got := pl.getConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("config version = %q, want %s (permanent failures commit + ack)", got, testNewConfigVersion)
	}
	if got := icmpCheckCount(pl); got != 1 {
		t.Fatalf("icmp checks applied = %d, want 1: other sections still apply", got)
	}

	failures := pl.configSectionFailureSnapshot()
	failure, ok := failures[configSectionVisibility]
	if !ok {
		t.Fatalf("expected a recorded visibility section failure, got %v", failures)
	}
	if failure.disposition != addonDeliveryPermanentFailure {
		t.Fatalf("visibility failure disposition = %v, want permanent", failure.disposition)
	}
	if !strings.Contains(failure.reason, "capture_interfaces") {
		t.Fatalf("visibility failure reason = %q, want the decoder error verbatim", failure.reason)
	}
	if len(failure.addonIDs) != 1 || failure.addonIDs[0] != agentnetprobe.DefaultSidecarName {
		t.Fatalf("visibility failure addonIDs = %q, want [%q]", failure.addonIDs, agentnetprobe.DefaultSidecarName)
	}
	if failure.since.IsZero() {
		t.Fatal("visibility failure must carry a since timestamp")
	}

	// The ack carries the failed section status; the other sections read success.
	statuses := pl.configSectionStatuses()
	bySection := make(map[string]*proto.ConfigSectionStatus, len(statuses))
	for _, status := range statuses {
		bySection[status.GetSection()] = status
	}
	vis := bySection[configSectionVisibility]
	if vis.GetDisposition() != configSectionDispositionPermanent {
		t.Fatalf("ack visibility disposition = %q, want %q", vis.GetDisposition(), configSectionDispositionPermanent)
	}
	if !strings.Contains(vis.GetError(), "capture_interfaces") || vis.GetSince() == 0 {
		t.Fatalf("ack visibility status = %v, want the verbatim error and a since timestamp", vis)
	}
	for _, section := range []string{configSectionBumblebee, configSectionEndpointInventory, configSectionAddons} {
		if got := bySection[section].GetDisposition(); got != configSectionDispositionSuccess {
			t.Fatalf("ack %s disposition = %q, want success", section, got)
		}
	}
}

// Permanent failures escalate once: an identical failing payload delivered again (even
// under a new config version) is skipped without re-attempting the apply, and the
// original observation time is preserved.
func TestApplyConfigResponsePermanentFailureNotReattemptedForIdenticalPayload(t *testing.T) {
	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	manager := &recordingSidecarLifecycleManager{}
	pl := NewPushLoop(&Server{
		config:          &ServerConfig{AgentID: "agent-1"},
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  manager,
		sidecarStatus:   manager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	badNetprobe := &proto.AddonAssignmentConfig{
		AddonId:     agentnetprobe.DefaultSidecarName,
		Enabled:     true,
		Supervision: addonSupervisionSystemdService,
		ConfigJson:  []byte(`{"capture_interfaces": 42}`),
	}
	makeResp := func(version string) *proto.AgentConfigResponse {
		return &proto.AgentConfigResponse{
			ConfigVersion:    version,
			VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
			Addons:           []*proto.AddonAssignmentConfig{badNetprobe},
		}
	}

	if !pl.applyConfigResponse(context.Background(), makeResp("v1"), "control") {
		t.Fatal("first apply must commit despite the permanent failure")
	}
	first := pl.configSectionFailureSnapshot()[configSectionVisibility]
	if first.version != "v1" {
		t.Fatalf("recorded version = %q, want v1", first.version)
	}

	// A new config version with the IDENTICAL section payload: the section is skipped,
	// the recorded state (version of first observation, since) is unchanged.
	if !pl.applyConfigResponse(context.Background(), makeResp("v2"), "control") {
		t.Fatal("second apply must commit as well")
	}
	second := pl.configSectionFailureSnapshot()[configSectionVisibility]
	if second.version != "v1" || !second.since.Equal(first.since) {
		t.Fatalf("identical payload must not be re-recorded: got version=%q since=%v, want version=v1 since=%v",
			second.version, second.since, first.since)
	}
}

// applyConfigSection: the state machine skips re-running an apply whose identical
// payload already failed permanently, re-runs it when the payload changes, and clears
// the record on success.
func TestApplyConfigSectionSkipAndRecovery(t *testing.T) {
	pl := newDeliveryTestPushLoop(t)

	calls := 0
	failing := func() (addonDeliveryDisposition, error) {
		calls++
		return addonDeliveryPermanentFailure, errTestSectionBoom
	}

	if got := pl.applyConfigSection(configSectionBumblebee, "v1", "hash-a", failing); got != addonDeliveryPermanentFailure {
		t.Fatalf("disposition = %v, want permanent", got)
	}
	if calls != 1 {
		t.Fatalf("apply calls = %d, want 1", calls)
	}

	// Identical payload: skipped (no re-attempt, no re-log).
	if got := pl.applyConfigSection(configSectionBumblebee, "v1", "hash-a", failing); got != addonDeliveryPermanentFailure {
		t.Fatalf("disposition = %v, want permanent from recorded state", got)
	}
	if calls != 1 {
		t.Fatalf("apply calls = %d, want 1: identical payloads must not be re-attempted", calls)
	}

	// Changed payload: re-evaluated.
	succeeded := func() (addonDeliveryDisposition, error) { return addonDeliverySucceeded, nil }
	if got := pl.applyConfigSection(configSectionBumblebee, "v2", "hash-b", succeeded); got != addonDeliverySucceeded {
		t.Fatalf("disposition = %v, want success after payload change", got)
	}
	if failures := pl.configSectionFailureSnapshot(); len(failures) != 0 {
		t.Fatalf("success must clear the recorded failure, got %v", failures)
	}
}

// A permanently-failing add-on config section synthesizes an unhealthy `addon:<id>`
// status entry — and, unlike artifact-delivery failures, OVERRIDES a running entry,
// because the process is alive but running with the wrong config.
func TestConfigApplyFailureStatusesOverridesRunningAddon(t *testing.T) {
	pl := newDeliveryTestPushLoop(t)
	pl.recordConfigSectionFailure(
		configSectionVisibility, "hash-a", "v1",
		&addonConfigApplyError{addonID: "netprobe", err: errTestSectionBoom},
		addonDeliveryPermanentFailure,
	)

	// No existing entry: one is synthesized.
	statuses := pl.configApplyFailureStatuses(nil)
	if len(statuses) != 1 {
		t.Fatalf("synthesized statuses = %d, want 1 (%v)", len(statuses), statuses)
	}
	if statuses[0].GetName() != testNetprobeAddonStatusName ||
		statuses[0].GetState() != string(agentaddon.StateUnhealthy) ||
		!strings.Contains(statuses[0].GetLastError(), "section boom") {
		t.Fatalf("synthesized status = %v, want unhealthy addon:netprobe with the failure reason", statuses[0])
	}

	// A RUNNING entry for the same add-on is overridden in place (config-broken must not
	// read as healthy), and no duplicate entry is appended.
	existing := []*proto.SidecarStatus{{Name: testNetprobeAddonStatusName, State: string(agentaddon.StateRunning)}}
	extra := pl.configApplyFailureStatuses(existing)
	if len(extra) != 0 {
		t.Fatalf("expected no synthesized duplicates, got %v", extra)
	}
	if existing[0].GetState() != string(agentaddon.StateUnhealthy) {
		t.Fatalf("existing status state = %q, want unhealthy override", existing[0].GetState())
	}
	if !strings.Contains(existing[0].GetLastError(), "config apply failed") {
		t.Fatalf("existing status last_error = %q, want the config-apply reason", existing[0].GetLastError())
	}
}

// Section failures without an add-on attribution do not touch the AddonStatus model.
func TestConfigApplyFailureStatusesIgnoresUnattributedSections(t *testing.T) {
	pl := newDeliveryTestPushLoop(t)
	pl.recordConfigSectionFailure(
		configSectionBumblebee, "hash-a", "v1", errTestSectionBoom, addonDeliveryPermanentFailure)

	if statuses := pl.configApplyFailureStatuses(nil); len(statuses) != 0 {
		t.Fatalf("expected no addon statuses for an unattributed section failure, got %v", statuses)
	}
}

// Re-recording the identical failure keeps the original since timestamp (escalate once);
// a different reason for the same section replaces the record with a fresh observation.
func TestRecordConfigSectionFailureIdenticalKeepsSince(t *testing.T) {
	pl := newDeliveryTestPushLoop(t)

	pl.recordConfigSectionFailure(configSectionAddons, "", "v1", errTestSectionBoom, addonDeliveryPermanentFailure)
	first := pl.configSectionFailureSnapshot()[configSectionAddons]

	pl.recordConfigSectionFailure(configSectionAddons, "", "v2", errTestSectionBoom, addonDeliveryPermanentFailure)
	second := pl.configSectionFailureSnapshot()[configSectionAddons]
	if !second.since.Equal(first.since) || second.version != "v1" {
		t.Fatalf("identical failure must keep the original record, got %+v want %+v", second, first)
	}

	pl.recordConfigSectionFailure(configSectionAddons, "", "v3", errTestPermanentDelivery, addonDeliveryPermanentFailure)
	third := pl.configSectionFailureSnapshot()[configSectionAddons]
	if third.version != "v3" || third.reason == second.reason {
		t.Fatalf("a changed failure reason must be re-recorded, got %+v", third)
	}
}

// A permanent per-add-on delivery failure surfaces as a permanent `addons` section
// status on the ack (aggregated reason), without deferring the version.
func TestApplyConfigResponseAddonPermanentFailureReportedOnAckSection(t *testing.T) {
	srv, _ := statusServer(t, http.StatusNotFound)
	pl := newDeliveryTestPushLoop(t)

	if !pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: "v1",
		Addons:        []*proto.AddonAssignmentConfig{sidecar404Assignment("netprobe", srv.URL)},
	}, "poll") {
		t.Fatal("a permanent add-on delivery failure must not defer the version")
	}

	statuses := pl.configSectionStatuses()
	for _, status := range statuses {
		if status.GetSection() != configSectionAddons {
			continue
		}
		if status.GetDisposition() != configSectionDispositionPermanent {
			t.Fatalf("addons section disposition = %q, want permanent", status.GetDisposition())
		}
		if !strings.Contains(status.GetError(), "netprobe") {
			t.Fatalf("addons section error = %q, want the failing add-on id", status.GetError())
		}
		return
	}
	t.Fatal("no addons section status found on the ack")
}

// backdateConfigSectionFailure moves a recorded section failure's first-seen time into
// the past, standing in for the wall-clock time that passes between config resends.
func backdateConfigSectionFailure(t *testing.T, pl *PushLoop, section string, by time.Duration) {
	t.Helper()

	pl.configSectionMu.Lock()
	defer pl.configSectionMu.Unlock()

	failure, ok := pl.configSectionFailures[section]
	if !ok {
		t.Fatalf("no recorded %s failure to backdate", section)
	}
	failure.since = failure.since.Add(-by)
	pl.configSectionFailures[section] = failure
}

// sentConfigAcks returns the config acks the agent sent on the control stream.
func sentConfigAcks(stream *fakeControlStreamClient) []*proto.ConfigAck {
	stream.mu.Lock()
	defer stream.mu.Unlock()

	var acks []*proto.ConfigAck
	for _, req := range stream.sent {
		if ack := req.GetConfigAck(); ack != nil {
			acks = append(acks, ack)
		}
	}

	return acks
}

func sectionStatus(statuses []*proto.ConfigSectionStatus, section string) *proto.ConfigSectionStatus {
	for _, status := range statuses {
		if status.GetSection() == section {
			return status
		}
	}

	return nil
}

// An add-on assignment that never stops failing transiently (here a 5xx artifact
// download; in the field, a native add-on whose new version never passes health) used
// to defer the version commit forever. Once the escalation bound is reached for the
// same payload, the version commits and the ack reports the add-on section as a
// permanent failure naming the add-on, which also reads unhealthy rather than applied.
func TestControlConfigTransientAddonFailureEscalatesAfterBound(t *testing.T) {
	srv, _ := statusServer(t, http.StatusServiceUnavailable)
	pl := newDeliveryTestPushLoop(t)
	pl.setConfigVersion(testOldConfigVersion)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	cfg := &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons:        []*proto.AddonAssignmentConfig{sidecar404Assignment("netprobe", srv.URL)},
	}

	// Reaching the attempt count quickly (a burst of resends) is not enough on its own.
	for range transientSectionEscalationAttempts {
		pl.applyControlConfig(t.Context(), cfg, sender)
	}
	if acks := sentConfigAcks(stream); len(acks) != 0 {
		t.Fatalf("sent %d config acks before the escalation age, want 0", len(acks))
	}
	if got := pl.getConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("config version = %q, want %s while the bound is not reached", got, testOldConfigVersion)
	}

	backdateConfigSectionFailure(t, pl, configSectionAddons, transientSectionEscalationAge)
	firstSeen := pl.configSectionFailureSnapshot()[configSectionAddons].since

	pl.applyControlConfig(t.Context(), cfg, sender)

	acks := sentConfigAcks(stream)
	if len(acks) != 1 {
		t.Fatalf("sent %d config acks after the bound, want 1", len(acks))
	}
	if got := acks[0].GetConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("acked version = %q, want %s", got, testNewConfigVersion)
	}
	if got := pl.getConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("committed version = %q, want %s", got, testNewConfigVersion)
	}

	addons := sectionStatus(acks[0].GetSectionStatuses(), configSectionAddons)
	if addons.GetDisposition() != configSectionDispositionPermanent {
		t.Fatalf("ack addons disposition = %q, want %q", addons.GetDisposition(), configSectionDispositionPermanent)
	}
	if !strings.Contains(addons.GetError(), "netprobe") {
		t.Fatalf("ack addons error = %q, want it to name the add-on", addons.GetError())
	}
	if addons.GetSince() != firstSeen.Unix() {
		t.Fatalf("ack addons since = %d, want the first transient observation %d", addons.GetSince(), firstSeen.Unix())
	}

	statuses := pl.configApplyFailureStatuses(nil)
	if len(statuses) != 1 || statuses[0].GetName() != testNetprobeAddonStatusName ||
		statuses[0].GetState() != string(agentaddon.StateUnhealthy) {
		t.Fatalf("add-on statuses = %v, want addon:netprobe unhealthy", statuses)
	}
}

// The escalation is per payload: an escalated section is still re-attempted (the
// condition may clear), a changed payload starts a fresh count, and a success clears the
// state so the same payload failing again starts over as transient.
func TestApplyConfigSectionTransientEscalationReArms(t *testing.T) {
	pl := newDeliveryTestPushLoop(t)

	calls := 0
	transient := func() (addonDeliveryDisposition, error) {
		calls++
		return addonDeliveryTransientFailure, errTestSectionBoom
	}
	succeeded := func() (addonDeliveryDisposition, error) { return addonDeliverySucceeded, nil }

	for range transientSectionEscalationAttempts {
		if got := pl.applyConfigSection(configSectionBumblebee, "v1", "hash-a", transient); got != addonDeliveryTransientFailure {
			t.Fatalf("disposition before the bound = %v, want transient", got)
		}
	}
	backdateConfigSectionFailure(t, pl, configSectionBumblebee, transientSectionEscalationAge)

	if got := pl.applyConfigSection(configSectionBumblebee, "v2", "hash-a", transient); got != addonDeliveryPermanentFailure {
		t.Fatalf("disposition at the bound = %v, want permanent", got)
	}
	callsAtEscalation := calls
	if got := pl.applyConfigSection(configSectionBumblebee, "v3", "hash-a", transient); got != addonDeliveryPermanentFailure {
		t.Fatalf("disposition after escalation = %v, want permanent", got)
	}
	if calls != callsAtEscalation+1 {
		t.Fatal("an escalated transient section must still be re-attempted, not skipped")
	}

	if got := pl.applyConfigSection(configSectionBumblebee, "v4", "hash-b", transient); got != addonDeliveryTransientFailure {
		t.Fatalf("disposition after a payload change = %v, want transient", got)
	}
	if got := pl.configSectionFailureSnapshot()[configSectionBumblebee]; got.attempts != 1 || got.version != "v4" {
		t.Fatalf("failure after a payload change = %+v, want a fresh count from v4", got)
	}

	backdateConfigSectionFailure(t, pl, configSectionBumblebee, transientSectionEscalationAge)
	if got := pl.applyConfigSection(configSectionBumblebee, "v5", "hash-b", succeeded); got != addonDeliverySucceeded {
		t.Fatalf("disposition on success = %v, want success", got)
	}
	if got := pl.applyConfigSection(configSectionBumblebee, "v6", "hash-b", transient); got != addonDeliveryTransientFailure {
		t.Fatalf("disposition after a success = %v, want transient", got)
	}
}

// While a section defers the commit no ack is sent, so the hello carries the current
// section state, transient failures included. Before the first apply attempt there is
// no state to report and the field is omitted.
func TestControlHelloReportsTransientSectionStatuses(t *testing.T) {
	srv, _ := statusServer(t, http.StatusServiceUnavailable)
	pl := newDeliveryTestPushLoop(t)
	pl.setConfigVersion(testOldConfigVersion)

	if got := pl.buildControlHelloRequest().GetHello().GetConfigSectionStatuses(); got != nil {
		t.Fatalf("hello section statuses before any apply = %v, want none", got)
	}

	if pl.applyConfigResponse(t.Context(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons:        []*proto.AddonAssignmentConfig{sidecar404Assignment("netprobe", srv.URL)},
	}, "poll") {
		t.Fatal("a transient add-on failure must defer the version")
	}

	hello := pl.buildControlHelloRequest().GetHello()
	if got := hello.GetConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("hello config version = %q, want the committed %s", got, testOldConfigVersion)
	}
	addons := sectionStatus(hello.GetConfigSectionStatuses(), configSectionAddons)
	if addons.GetDisposition() != configSectionDispositionTransient ||
		!strings.Contains(addons.GetError(), "netprobe") || addons.GetSince() == 0 {
		t.Fatalf("hello addons status = %v, want transient_failure naming netprobe with a since time", addons)
	}
	if got := sectionStatus(hello.GetConfigSectionStatuses(), configSectionBumblebee).GetDisposition(); got != configSectionDispositionSuccess {
		t.Fatalf("hello bumblebee disposition = %q, want success", got)
	}
}

// gateAddonManager fails supervisor Apply until fail is cleared.
type gateAddonManager struct {
	recordingAddonManager
	fail bool
}

func (m *gateAddonManager) Apply(_ context.Context, specs []agentaddon.Spec) error {
	m.applyCalls++
	m.applied = append([]agentaddon.Spec(nil), specs...)
	if m.fail {
		return errTransientSupervisorFailure
	}

	return nil
}

func osPackageSidecarAssignment(addonID, binaryPath string) *proto.AddonAssignmentConfig {
	return &proto.AddonAssignmentConfig{
		AddonId:     addonID,
		Enabled:     true,
		Version:     "1.0.0",
		Delivery:    "os_package",
		Supervision: addonSupervisionAgentSidecar,
		BinaryPath:  binaryPath,
	}
}

func newAddonManagerPushLoop(t *testing.T, manager agentaddon.AddonManager) *PushLoop {
	t.Helper()

	pl := NewPushLoop(&Server{
		config:       &ServerConfig{AgentID: "agent-test"},
		addonManager: manager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	return pl
}

// A committed version with no escalated section stays on the unchanged-version
// short-circuit: sections are not applied again.
func TestSameVersionShortCircuitSkipsSectionsWhenNoneEscalated(t *testing.T) {
	manager := &recordingAddonManager{}
	pl := newAddonManagerPushLoop(t, manager)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	cfg := &proto.AgentConfigResponse{
		ConfigVersion: "cfg-committed",
		Addons: []*proto.AddonAssignmentConfig{
			osPackageSidecarAssignment(testPowerDNSAddonID, "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon"),
		},
	}

	pl.applyControlConfig(t.Context(), cfg, sender)
	if manager.applyCalls != 1 {
		t.Fatalf("supervisor Apply calls = %d, want 1", manager.applyCalls)
	}
	if got := pl.getConfigVersion(); got != "cfg-committed" {
		t.Fatalf("committed version = %q, want cfg-committed", got)
	}

	pl.recordConfigSectionFailure(
		configSectionBumblebee, "unrelated-payload", "v0", errTestSectionBoom, addonDeliveryPermanentFailure)

	pl.applyControlConfig(t.Context(), cfg, sender)

	if manager.applyCalls != 1 {
		t.Fatalf("supervisor Apply calls = %d, want 1: a non-escalated committed version must not re-run sections", manager.applyCalls)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("same-version short-circuit re-ran the bumblebee section")
	}
	if got := pl.getConfigVersion(); got != "cfg-committed" {
		t.Fatalf("committed version = %q, want cfg-committed", got)
	}
}

// A full same-version control delivery re-runs only that section. A later
// delivery whose failure has cleared succeeds, drops the record, and acks the
// committed version with a success status. An unchanged failure is not acked again.
// The post-ack poll is NotModified; TestEscalatedSectionRetriesOnNotModifiedPoll
// covers that path.
func TestEscalatedSectionRetriesOnSameVersionDelivery(t *testing.T) {
	manager := &gateAddonManager{fail: true}
	pl := newAddonManagerPushLoop(t, manager)
	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	cfg := &proto.AgentConfigResponse{
		ConfigVersion: "cfg-escalated",
		Addons: []*proto.AddonAssignmentConfig{
			osPackageSidecarAssignment(testPowerDNSAddonID, "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon"),
		},
	}

	for range transientSectionEscalationAttempts {
		pl.applyControlConfig(t.Context(), cfg, sender)
	}
	if acks := sentConfigAcks(stream); len(acks) != 0 {
		t.Fatalf("sent %d config acks before the escalation age, want 0", len(acks))
	}

	backdateConfigSectionFailure(t, pl, configSectionAddons, transientSectionEscalationAge)
	pl.applyControlConfig(t.Context(), cfg, sender)

	acks := sentConfigAcks(stream)
	if len(acks) != 1 {
		t.Fatalf("sent %d config acks at escalation, want 1", len(acks))
	}
	if got := sectionStatus(acks[0].GetSectionStatuses(), configSectionAddons).GetDisposition(); got != configSectionDispositionPermanent {
		t.Fatalf("ack addons disposition = %q, want permanent", got)
	}
	statuses := pl.configApplyFailureStatuses(nil)
	if len(statuses) != 1 || statuses[0].GetName() != "addon:"+testPowerDNSAddonID ||
		statuses[0].GetState() != string(agentaddon.StateUnhealthy) {
		t.Fatalf("add-on statuses = %v, want addon:%s unhealthy", statuses, testPowerDNSAddonID)
	}
	callsAtEscalation := manager.applyCalls

	pl.recordConfigSectionFailure(
		configSectionBumblebee, "unrelated-payload", "v0", errTestSectionBoom, addonDeliveryPermanentFailure)

	pl.applyControlConfig(t.Context(), cfg, sender)
	if manager.applyCalls != callsAtEscalation+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d: the escalated section must be retried", manager.applyCalls, callsAtEscalation+1)
	}
	if acks := sentConfigAcks(stream); len(acks) != 1 {
		t.Fatalf("sent %d config acks while the escalated failure was unchanged, want 1", len(acks))
	}
	if failure := pl.configSectionFailureSnapshot()[configSectionAddons]; !failure.escalated {
		t.Fatalf("addons failure = %+v, want it to stay escalated", failure)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("same-version retry re-ran a section that was not escalated")
	}

	manager.fail = false
	pl.applyControlConfig(t.Context(), cfg, sender)

	if manager.applyCalls != callsAtEscalation+2 {
		t.Fatalf("supervisor Apply calls = %d, want %d", manager.applyCalls, callsAtEscalation+2)
	}
	acks = sentConfigAcks(stream)
	if len(acks) != 2 {
		t.Fatalf("sent %d config acks after the section recovered, want 2", len(acks))
	}
	if got := acks[1].GetConfigVersion(); got != "cfg-escalated" {
		t.Fatalf("recovery ack version = %q, want cfg-escalated", got)
	}
	recovered := sectionStatus(acks[1].GetSectionStatuses(), configSectionAddons)
	if recovered.GetDisposition() != configSectionDispositionSuccess || recovered.GetError() != "" {
		t.Fatalf("recovery ack addons status = %+v, want success with an empty error", recovered)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionAddons]; ok {
		t.Fatal("recovered add-on section failure record was not cleared")
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("recovery re-ran a section that was not escalated")
	}
	if got := pl.getConfigVersion(); got != "cfg-escalated" {
		t.Fatalf("committed version = %q, want cfg-escalated", got)
	}
	if statuses := pl.configApplyFailureStatuses(nil); len(statuses) != 0 {
		t.Fatalf("add-on statuses after recovery = %v, want none unhealthy", statuses)
	}
	helloAddons := sectionStatus(pl.buildControlHelloRequest().GetHello().GetConfigSectionStatuses(), configSectionAddons)
	if helloAddons.GetDisposition() != configSectionDispositionSuccess {
		t.Fatalf("hello addons disposition = %q, want success", helloAddons.GetDisposition())
	}

	callsAfterRecovery := manager.applyCalls
	pl.applyControlConfig(t.Context(), cfg, sender)
	if manager.applyCalls != callsAfterRecovery {
		t.Fatalf("supervisor Apply calls = %d, want %d: a cleared section must not be retried on the next same-version delivery", manager.applyCalls, callsAfterRecovery)
	}
}

// A supervisor Apply failure names the add-ons that built a spec and the add-ons
// whose delivery was deferred and so never reached the supervisor.
func TestSupervisorApplyFailureUnionsDeferredAddonIDs(t *testing.T) {
	srv, _ := statusServer(t, http.StatusServiceUnavailable)
	pl := newAddonManagerPushLoop(t, &gateAddonManager{fail: true})

	disposition, err := pl.applyAddonAssignments(t.Context(), []*proto.AddonAssignmentConfig{
		osPackageSidecarAssignment(testPowerDNSAddonID, "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon"),
		sidecar404Assignment("netprobe", srv.URL),
	})
	if disposition != addonDeliveryTransientFailure {
		t.Fatalf("disposition = %v, want transient", disposition)
	}

	var deferred *addonAssignmentsDeferredError
	if !errors.As(err, &deferred) {
		t.Fatalf("error = %v, want addonAssignmentsDeferredError", err)
	}
	if len(deferred.addonIDs) != 2 || deferred.addonIDs[0] != testPowerDNSAddonID || deferred.addonIDs[1] != "netprobe" {
		t.Fatalf("deferred addon IDs = %v, want [%s netprobe]", deferred.addonIDs, testPowerDNSAddonID)
	}
}

// pollConfigServer answers the unary GetConfig the agent poll loop calls.
type pollConfigServer struct {
	proto.UnimplementedAgentGatewayServiceServer
	mu      sync.Mutex
	respond func(*proto.AgentConfigRequest) *proto.AgentConfigResponse
}

func (s *pollConfigServer) GetConfig(_ context.Context, req *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	s.mu.Lock()
	respond := s.respond
	s.mu.Unlock()
	if respond == nil {
		return &proto.AgentConfigResponse{NotModified: true}, nil
	}

	return respond(req), nil
}

// attachPollGateway connects pl.gateway to a local server that serves respond.
func attachPollGateway(t *testing.T, pl *PushLoop, respond func(*proto.AgentConfigRequest) *proto.AgentConfigResponse) {
	t.Helper()
	t.Setenv("SR_ALLOW_INSECURE", "true")

	lis, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, &pollConfigServer{respond: respond})
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(server.Stop)

	client := agentgateway.NewGatewayClient(lis.Addr().String(), nil, logger.NewTestLogger())
	t.Cleanup(func() { _ = client.Disconnect() })
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if err := client.Connect(ctx); err != nil {
		t.Fatalf("connect gateway: %v", err)
	}
	pl.gateway = client
}

// notModifiedDecoy is a poll body whose section fields must never be applied.
func notModifiedDecoy() *proto.AgentConfigResponse {
	return &proto.AgentConfigResponse{
		NotModified: true,
		Addons: []*proto.AddonAssignmentConfig{
			osPackageSidecarAssignment("decoy-addon", "/no/such/decoy"),
		},
	}
}

func cloneConfig(cfg *proto.AgentConfigResponse) *proto.AgentConfigResponse {
	cloned, _ := goproto.Clone(cfg).(*proto.AgentConfigResponse)
	return cloned
}

// After the escalation ack, polls are NotModified and carry no section payload.
// The poll still retries the escalated section from the retained full response,
// and a status change acks the committed version. An unchanged failure does not.
func TestEscalatedSectionRetriesOnNotModifiedPoll(t *testing.T) {
	manager := &gateAddonManager{fail: true}
	pl := newAddonManagerPushLoop(t, manager)
	full := &proto.AgentConfigResponse{
		ConfigVersion: "cfg-escalated",
		Addons: []*proto.AddonAssignmentConfig{
			osPackageSidecarAssignment(testPowerDNSAddonID, "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon"),
		},
	}
	var phase atomic.Int32
	attachPollGateway(t, pl, func(*proto.AgentConfigRequest) *proto.AgentConfigResponse {
		if phase.Load() == 0 {
			return cloneConfig(full)
		}
		return notModifiedDecoy()
	})

	for range transientSectionEscalationAttempts {
		pl.fetchAndApplyConfig(t.Context())
	}
	if got := pl.getConfigVersion(); got != "" {
		t.Fatalf("committed version = %q, want empty before the escalation age", got)
	}
	backdateConfigSectionFailure(t, pl, configSectionAddons, transientSectionEscalationAge)
	pl.fetchAndApplyConfig(t.Context())
	if got := pl.getConfigVersion(); got != "cfg-escalated" {
		t.Fatalf("committed version = %q, want cfg-escalated", got)
	}
	if failure := pl.configSectionFailureSnapshot()[configSectionAddons]; !failure.escalated {
		t.Fatalf("addons failure = %+v, want escalated", failure)
	}
	callsAtEscalation := manager.applyCalls

	pl.recordConfigSectionFailure(
		configSectionBumblebee, "unrelated-payload", "v0", errTestSectionBoom, addonDeliveryPermanentFailure)
	stream := &fakeControlStreamClient{}
	pl.applyControlConfig(t.Context(), notModifiedDecoy(), newControlStreamSender(stream))
	if manager.applyCalls != callsAtEscalation+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d: control NotModified must retry the retained section", manager.applyCalls, callsAtEscalation+1)
	}
	if len(manager.applied) != 1 || manager.applied[0].ID != testPowerDNSAddonID {
		t.Fatalf("applied specs = %#v, want the retained %s assignment", manager.applied, testPowerDNSAddonID)
	}
	if acks := sentConfigAcks(stream); len(acks) != 0 {
		t.Fatalf("sent %d config acks while the escalated failure was unchanged, want 0", len(acks))
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("NotModified retry re-ran a section that was not escalated")
	}

	manager.fail = false
	phase.Store(1)
	pl.setControlStreamSender(newControlStreamSender(stream))
	pl.fetchAndApplyConfig(t.Context())

	if manager.applyCalls != callsAtEscalation+2 {
		t.Fatalf("supervisor Apply calls = %d, want %d", manager.applyCalls, callsAtEscalation+2)
	}
	if len(manager.applied) != 1 || manager.applied[0].ID != testPowerDNSAddonID {
		t.Fatalf("applied specs = %#v, want the retained %s assignment", manager.applied, testPowerDNSAddonID)
	}
	acks := sentConfigAcks(stream)
	if len(acks) != 1 {
		t.Fatalf("sent %d config acks after the NotModified poll recovered, want 1", len(acks))
	}
	if got := acks[0].GetConfigVersion(); got != "cfg-escalated" {
		t.Fatalf("recovery ack version = %q, want cfg-escalated", got)
	}
	recovered := sectionStatus(acks[0].GetSectionStatuses(), configSectionAddons)
	if recovered.GetDisposition() != configSectionDispositionSuccess || recovered.GetError() != "" {
		t.Fatalf("recovery ack addons status = %+v, want success with an empty error", recovered)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionAddons]; ok {
		t.Fatal("recovered add-on section failure record was not cleared")
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("recovery re-ran a section that was not escalated")
	}
	if got := pl.getConfigVersion(); got != "cfg-escalated" {
		t.Fatalf("committed version = %q, want cfg-escalated", got)
	}
	if statuses := pl.configApplyFailureStatuses(nil); len(statuses) != 0 {
		t.Fatalf("add-on statuses after recovery = %v, want none unhealthy", statuses)
	}
	helloAddons := sectionStatus(pl.buildControlHelloRequest().GetHello().GetConfigSectionStatuses(), configSectionAddons)
	if helloAddons.GetDisposition() != configSectionDispositionSuccess {
		t.Fatalf("hello addons disposition = %q, want success", helloAddons.GetDisposition())
	}

	pl.fetchAndApplyConfig(t.Context())
	if manager.applyCalls != callsAtEscalation+2 {
		t.Fatalf("supervisor Apply calls = %d, want %d: a cleared section must not be retried on the next poll", manager.applyCalls, callsAtEscalation+2)
	}
	if acks := sentConfigAcks(stream); len(acks) != 1 {
		t.Fatalf("sent %d config acks when the poll changed nothing, want 1", len(acks))
	}
}

func systemdNetprobeAssignment() *proto.AddonAssignmentConfig {
	return &proto.AddonAssignmentConfig{
		AddonId:     agentnetprobe.DefaultSidecarName,
		Enabled:     true,
		Version:     "1.0.0",
		Delivery:    "os_package",
		Supervision: addonSupervisionSystemdService,
	}
}

// A visibility failure that escalates blocks systemd netprobe activation. The
// next NotModified poll retries visibility from the retained response and, once
// that succeeds, runs the add-on section in the same cycle so the unit activation
// is attempted. The unsigned assignment is rejected, which is the activation.
func TestVisibilityEscalationRecoveryActivatesBlockedNetprobe(t *testing.T) {
	dir := t.TempDir()
	lifecycle := &recordingSidecarLifecycleManager{
		statuses: []sidecar.Status{{
			Name:       agentnetprobe.DefaultSidecarName,
			ConfigPath: filepath.Join(dir, "netprobe.json"),
		}},
		startAttachErr: errStartAttachTest,
	}
	addons := &recordingAddonManager{}
	pl := NewPushLoop(&Server{
		config:          &ServerConfig{AgentID: "agent-test"},
		addonManager:    addons,
		netprobeSidecar: agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()}),
		sidecarManager:  lifecycle,
		sidecarStatus:   lifecycle,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	full := &proto.AgentConfigResponse{
		ConfigVersion:    "cfg-visibility",
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
		Addons: []*proto.AddonAssignmentConfig{
			systemdNetprobeAssignment(),
			osPackageSidecarAssignment(testPowerDNSAddonID, "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon"),
		},
	}
	var phase atomic.Int32
	attachPollGateway(t, pl, func(*proto.AgentConfigRequest) *proto.AgentConfigResponse {
		if phase.Load() == 0 {
			return cloneConfig(full)
		}
		return notModifiedDecoy()
	})

	for range transientSectionEscalationAttempts {
		pl.fetchAndApplyConfig(t.Context())
	}
	backdateConfigSectionFailure(t, pl, configSectionVisibility, transientSectionEscalationAge)
	pl.fetchAndApplyConfig(t.Context())

	if got := pl.getConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("committed version = %q, want cfg-visibility", got)
	}
	if failure := pl.configSectionFailureSnapshot()[configSectionVisibility]; !failure.escalated {
		t.Fatalf("visibility failure = %+v, want escalated", failure)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionAddons]; ok {
		t.Fatal("add-on section was escalated; the netprobe should have been activation-blocked")
	}
	if _, ok := pl.addonDeliveryFailureSnapshot()[agentnetprobe.DefaultSidecarName]; ok {
		t.Fatal("netprobe was activated while visibility was still failed")
	}
	attachCallsAtEscalation := lifecycle.startAttachCalls
	applyCallsAtEscalation := addons.applyCalls
	if attachCallsAtEscalation == 0 || applyCallsAtEscalation == 0 {
		t.Fatalf("StartAttach calls = %d, supervisor Apply calls = %d, want both to have run", attachCallsAtEscalation, applyCallsAtEscalation)
	}

	pl.recordConfigSectionFailure(
		configSectionBumblebee, "unrelated-payload", "v0", errTestSectionBoom, addonDeliveryPermanentFailure)
	lifecycle.startAttachErr = nil
	phase.Store(1)
	stream := &fakeControlStreamClient{}
	pl.setControlStreamSender(newControlStreamSender(stream))
	pl.fetchAndApplyConfig(t.Context())

	if lifecycle.startAttachCalls != attachCallsAtEscalation+1 {
		t.Fatalf("StartAttach calls = %d, want %d", lifecycle.startAttachCalls, attachCallsAtEscalation+1)
	}
	if addons.applyCalls != applyCallsAtEscalation+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d: visibility recovery must re-run add-ons", addons.applyCalls, applyCallsAtEscalation+1)
	}
	if len(addons.applied) != 1 || addons.applied[0].ID != testPowerDNSAddonID {
		t.Fatalf("applied specs = %#v, want the retained %s assignment", addons.applied, testPowerDNSAddonID)
	}
	netprobeFailure, ok := pl.addonDeliveryFailureSnapshot()[agentnetprobe.DefaultSidecarName]
	if !ok || !strings.Contains(netprobeFailure.reason, "signature") {
		t.Fatalf("netprobe delivery failure = %+v, want the activation to reach signature verification", netprobeFailure)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionVisibility]; ok {
		t.Fatal("visibility failure record was not cleared")
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("visibility recovery re-ran a section that was not escalated")
	}
	if got := pl.getConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("committed version = %q, want cfg-visibility", got)
	}
	acks := sentConfigAcks(stream)
	if len(acks) != 1 {
		t.Fatalf("sent %d config acks after visibility recovered, want 1", len(acks))
	}
	if got := acks[0].GetConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("recovery ack version = %q, want cfg-visibility", got)
	}
	if got := sectionStatus(acks[0].GetSectionStatuses(), configSectionVisibility).GetDisposition(); got != configSectionDispositionSuccess {
		t.Fatalf("ack visibility disposition = %q, want success", got)
	}
	helloVisibility := sectionStatus(pl.buildControlHelloRequest().GetHello().GetConfigSectionStatuses(), configSectionVisibility)
	if helloVisibility.GetDisposition() != configSectionDispositionSuccess {
		t.Fatalf("hello visibility disposition = %q, want success", helloVisibility.GetDisposition())
	}

	pl.fetchAndApplyConfig(t.Context())
	if lifecycle.startAttachCalls != attachCallsAtEscalation+1 {
		t.Fatalf("StartAttach calls = %d, want %d: visibility must not be retried once it has recovered", lifecycle.startAttachCalls, attachCallsAtEscalation+1)
	}
	if addons.applyCalls != applyCallsAtEscalation+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d: a later NotModified poll must not re-run add-ons", addons.applyCalls, applyCallsAtEscalation+1)
	}
	if acks := sentConfigAcks(stream); len(acks) != 1 {
		t.Fatalf("sent %d config acks when the poll changed nothing, want 1", len(acks))
	}
}

// openPostCommitAddonTransient escalates visibility, then recovers it on a
// NotModified poll whose add-on supervisor fails. The add-on section is left
// transient on the committed version.
func openPostCommitAddonTransient(t *testing.T) (*PushLoop, *gateAddonManager, *fakeControlStreamClient, *atomic.Int32) {
	t.Helper()

	dir := t.TempDir()
	lifecycle := &recordingSidecarLifecycleManager{
		statuses: []sidecar.Status{{
			Name:       agentnetprobe.DefaultSidecarName,
			ConfigPath: filepath.Join(dir, "netprobe.json"),
		}},
		startAttachErr: errStartAttachTest,
	}
	manager := &gateAddonManager{}
	pl := NewPushLoop(&Server{
		config:          &ServerConfig{AgentID: "agent-test"},
		addonManager:    manager,
		netprobeSidecar: agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()}),
		sidecarManager:  lifecycle,
		sidecarStatus:   lifecycle,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	full := &proto.AgentConfigResponse{
		ConfigVersion:    "cfg-visibility",
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
		Addons: []*proto.AddonAssignmentConfig{
			systemdNetprobeAssignment(),
			osPackageSidecarAssignment(testPowerDNSAddonID, "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon"),
		},
	}
	phase := &atomic.Int32{}
	attachPollGateway(t, pl, func(*proto.AgentConfigRequest) *proto.AgentConfigResponse {
		if phase.Load() == 0 {
			return cloneConfig(full)
		}
		return notModifiedDecoy()
	})

	for range transientSectionEscalationAttempts {
		pl.fetchAndApplyConfig(t.Context())
	}
	backdateConfigSectionFailure(t, pl, configSectionVisibility, transientSectionEscalationAge)
	pl.fetchAndApplyConfig(t.Context())
	if failure := pl.configSectionFailureSnapshot()[configSectionVisibility]; !failure.escalated {
		t.Fatalf("visibility failure = %+v, want escalated", failure)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionAddons]; ok {
		t.Fatal("add-on section failed while netprobe activation was blocked")
	}

	pl.recordConfigSectionFailure(
		configSectionBumblebee, "unrelated-payload", "v0", errTestSectionBoom, addonDeliveryPermanentFailure)
	lifecycle.startAttachErr = nil
	manager.fail = true
	phase.Store(1)
	stream := &fakeControlStreamClient{}
	pl.setControlStreamSender(newControlStreamSender(stream))
	callsBeforeRecovery := manager.applyCalls
	pl.fetchAndApplyConfig(t.Context())

	if manager.applyCalls != callsBeforeRecovery+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d on visibility recovery", manager.applyCalls, callsBeforeRecovery+1)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionVisibility]; ok {
		t.Fatal("visibility failure record was not cleared")
	}
	addons := pl.configSectionFailureSnapshot()[configSectionAddons]
	if addons.disposition != addonDeliveryTransientFailure || addons.escalated || addons.attempts != 1 || addons.version != "cfg-visibility" {
		t.Fatalf("addons failure after recovery = %+v, want a new transient for cfg-visibility", addons)
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("recovery re-ran a section recorded for another version")
	}
	if got := pl.getConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("committed version = %q, want cfg-visibility", got)
	}

	return pl, manager, stream, phase
}

func TestPostCommitAddonTransientRetriesUntilSuccess(t *testing.T) {
	pl, manager, stream, _ := openPostCommitAddonTransient(t)
	callsAfterRecovery := manager.applyCalls

	pl.fetchAndApplyConfig(t.Context())
	if manager.applyCalls != callsAfterRecovery+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d: the transient add-on section must be retried", manager.applyCalls, callsAfterRecovery+1)
	}
	if got := pl.configSectionFailureSnapshot()[configSectionAddons].attempts; got != 2 {
		t.Fatalf("addon attempts = %d, want 2", got)
	}
	if acks := sentConfigAcks(stream); len(acks) != 1 {
		t.Fatalf("sent %d config acks while the transient failure was unchanged, want 1", len(acks))
	}

	// The unsigned netprobe records a permanent delivery failure once activation
	// runs. Dropping host visibility support removes that assignment so the
	// supervisor success can clear the section.
	setHostNetworkVisibilitySupportForTest(pl, false)
	manager.fail = false
	pl.fetchAndApplyConfig(t.Context())

	if _, ok := pl.configSectionFailureSnapshot()[configSectionAddons]; ok {
		t.Fatal("recovered add-on section failure record was not cleared")
	}
	if _, ok := pl.configSectionFailureSnapshot()[configSectionBumblebee]; !ok {
		t.Fatal("success retry re-ran a section recorded for another version")
	}
	acks := sentConfigAcks(stream)
	if len(acks) != 2 {
		t.Fatalf("sent %d config acks after the add-on section recovered, want 2", len(acks))
	}
	if got := acks[1].GetConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("recovery ack version = %q, want cfg-visibility", got)
	}
	recovered := sectionStatus(acks[1].GetSectionStatuses(), configSectionAddons)
	if recovered.GetDisposition() != configSectionDispositionSuccess || recovered.GetError() != "" {
		t.Fatalf("recovery ack addons status = %+v, want success", recovered)
	}
	helloAddons := sectionStatus(pl.buildControlHelloRequest().GetHello().GetConfigSectionStatuses(), configSectionAddons)
	if helloAddons.GetDisposition() != configSectionDispositionSuccess {
		t.Fatalf("hello addons disposition = %q, want success", helloAddons.GetDisposition())
	}
	if got := pl.getConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("committed version = %q, want cfg-visibility", got)
	}

	callsAfterSuccess := manager.applyCalls
	pl.fetchAndApplyConfig(t.Context())
	if manager.applyCalls != callsAfterSuccess {
		t.Fatalf("supervisor Apply calls = %d, want %d after the section cleared", manager.applyCalls, callsAfterSuccess)
	}
	if acks := sentConfigAcks(stream); len(acks) != 2 {
		t.Fatalf("sent %d config acks when the poll changed nothing, want 2", len(acks))
	}
}

func TestPostCommitAddonTransientRetriesUntilEscalation(t *testing.T) {
	pl, manager, stream, _ := openPostCommitAddonTransient(t)

	pl.fetchAndApplyConfig(t.Context())
	failure := pl.configSectionFailureSnapshot()[configSectionAddons]
	if failure.attempts != 2 || failure.escalated || failure.disposition != addonDeliveryTransientFailure {
		t.Fatalf("addons failure before the age bound = %+v, want transient attempts 2", failure)
	}
	if acks := sentConfigAcks(stream); len(acks) != 1 {
		t.Fatalf("sent %d config acks before escalation, want 1", len(acks))
	}

	backdateConfigSectionFailure(t, pl, configSectionAddons, transientSectionEscalationAge)
	callsBeforeEscalation := manager.applyCalls
	pl.fetchAndApplyConfig(t.Context())

	failure = pl.configSectionFailureSnapshot()[configSectionAddons]
	if !failure.escalated || failure.disposition != addonDeliveryPermanentFailure || failure.attempts < transientSectionEscalationAttempts {
		t.Fatalf("addons failure at the bound = %+v, want escalated permanent", failure)
	}
	if manager.applyCalls != callsBeforeEscalation+1 {
		t.Fatalf("supervisor Apply calls = %d, want %d at escalation", manager.applyCalls, callsBeforeEscalation+1)
	}
	acks := sentConfigAcks(stream)
	if len(acks) != 2 {
		t.Fatalf("sent %d config acks at escalation, want 2", len(acks))
	}
	if got := acks[1].GetConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("escalation ack version = %q, want cfg-visibility", got)
	}
	escalated := sectionStatus(acks[1].GetSectionStatuses(), configSectionAddons)
	if escalated.GetDisposition() != configSectionDispositionPermanent {
		t.Fatalf("escalation ack addons disposition = %q, want permanent", escalated.GetDisposition())
	}
	helloAddons := sectionStatus(pl.buildControlHelloRequest().GetHello().GetConfigSectionStatuses(), configSectionAddons)
	if helloAddons.GetDisposition() != configSectionDispositionPermanent {
		t.Fatalf("hello addons disposition = %q, want permanent", helloAddons.GetDisposition())
	}
	if got := pl.getConfigVersion(); got != "cfg-visibility" {
		t.Fatalf("committed version = %q, want cfg-visibility", got)
	}

	pl.fetchAndApplyConfig(t.Context())
	if manager.applyCalls != callsBeforeEscalation+2 {
		t.Fatalf("supervisor Apply calls = %d, want %d: an escalated section must still be retried", manager.applyCalls, callsBeforeEscalation+2)
	}
	if acks := sentConfigAcks(stream); len(acks) != 2 {
		t.Fatalf("sent %d config acks while the escalated failure was unchanged, want 2", len(acks))
	}
}
