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
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
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
