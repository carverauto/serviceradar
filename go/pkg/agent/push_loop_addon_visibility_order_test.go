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
	"sync/atomic"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
)

const (
	testNetprobeAddonID = "netprobe"
	testPowerDNSAddonID = "powerdns"
)

var errTransientSupervisorFailure = errors.New("transient supervisor failure")

type recordingAddonManager struct {
	applied     []agentaddon.Spec
	beforeApply func()
	applyCalls  int
}

func (m *recordingAddonManager) Apply(_ context.Context, specs []agentaddon.Spec) error {
	m.applyCalls++
	if m.beforeApply != nil {
		m.beforeApply()
	}
	m.applied = append([]agentaddon.Spec(nil), specs...)
	return nil
}

func (m *recordingAddonManager) SetCredentialResolver(coreaddon.CredentialResolver) {}

func (m *recordingAddonManager) Status() []agentaddon.Status {
	return nil
}

func (m *recordingAddonManager) RunCommand(context.Context, agentaddon.CommandInvocation) (coreaddon.CommandResult, error) {
	return coreaddon.CommandResult{}, agentaddon.ErrAddonCommandUnavailable
}

func (m *recordingAddonManager) PublishMetricFeed(string, []byte) int {
	return 0
}

func (m *recordingAddonManager) Stop(context.Context) error {
	return nil
}

type barrierAddonManager struct {
	recordingAddonManager
	firstApplyEntered chan struct{}
	releaseFirstApply chan struct{}
	calls             atomic.Int32
}

func (m *barrierAddonManager) Apply(_ context.Context, _ []agentaddon.Spec) error {
	if m.calls.Add(1) == 1 {
		close(m.firstApplyEntered)
		<-m.releaseFirstApply
	}

	return nil
}

type barrierVisibilityManager struct {
	stopCalls         atomic.Int32
	secondStopEntered chan struct{}
}

func (m *barrierVisibilityManager) Status() []sidecar.Status {
	return nil
}

func (m *barrierVisibilityManager) StartAttach(context.Context) error {
	return nil
}

func (m *barrierVisibilityManager) Stop(context.Context) error {
	if m.stopCalls.Add(1) == 2 {
		close(m.secondStopEntered)
	}

	return nil
}

func (m *barrierVisibilityManager) Mode() (started, attach bool) {
	// Keep visibility application observable on every response.
	return true, false
}

type failOnceAddonManager struct {
	recordingAddonManager
	calls atomic.Int32
}

func (m *failOnceAddonManager) Apply(_ context.Context, _ []agentaddon.Spec) error {
	if m.calls.Add(1) == 1 {
		return errTransientSupervisorFailure
	}

	return nil
}

func setHostNetworkVisibilitySupportForTest(p *PushLoop, supported bool) {
	p.hostNetworkVisibilitySupported = func() bool { return supported }
}

func TestApplyAddonAssignmentsSkipsAllNativeAddonsForKubernetesAgent(t *testing.T) {
	addons := &recordingAddonManager{}
	pl := NewPushLoop(&Server{
		config:       &ServerConfig{AgentID: kubernetesAgentID},
		addonManager: addons,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	disposition, err := pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{{
		AddonId:     testPowerDNSAddonID,
		Enabled:     true,
		Delivery:    "os_package",
		Supervision: addonSupervisionAgentSidecar,
		BinaryPath:  "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
	}})
	if disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyAddonAssignments() = %v (%v), want Kubernetes skip success", disposition, err)
	}
	if addons.applyCalls != 0 || len(addons.applied) != 0 {
		t.Fatalf("Kubernetes agent applied native add-ons: calls=%d specs=%#v", addons.applyCalls, addons.applied)
	}
}

func TestApplyAddonAssignmentsUnsupportedHostRemovesNetprobeAndReconcilesOtherAddons(t *testing.T) {
	dir := t.TempDir()
	override := `{
  "addons": [
    {
      "addon_id": "netprobe",
      "version": "1.0.0",
      "enabled": true,
      "binary_path": "/usr/local/lib/serviceradar/bin/serviceradar-netprobe",
      "delivery": "os_package",
      "supervision": "systemd_service"
    }
  ]
}`
	if err := os.WriteFile(filepath.Join(dir, addonLocalOverrideFile), []byte(override), 0o600); err != nil {
		t.Fatalf("write local add-on override: %v", err)
	}

	addons := &recordingAddonManager{}
	pl := NewPushLoop(&Server{
		configDir:    dir,
		addonManager: addons,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, false)
	pl.systemdRehydrateOnce.Do(func() {})
	pl.installedSystemdAddons = map[string][]string{
		agentnetprobe.DefaultSidecarName: {"serviceradar-netprobe.service"},
	}
	var uninstalled []string
	pl.uninstallSystemdAddonUnits = func(_ context.Context, units []string) error {
		uninstalled = append([]string(nil), units...)
		return nil
	}

	disposition, err := pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{
		{
			AddonId:     testPowerDNSAddonID,
			Enabled:     true,
			Delivery:    "os_package",
			Supervision: addonSupervisionAgentSidecar,
			BinaryPath:  "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
		},
	})
	if disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyAddonAssignments() = %v (%v), want success", disposition, err)
	}
	if len(addons.applied) != 1 || addons.applied[0].ID != testPowerDNSAddonID {
		t.Fatalf("applied add-ons = %#v, want only powerdns", addons.applied)
	}
	if len(uninstalled) != 1 || uninstalled[0] != "serviceradar-netprobe.service" {
		t.Fatalf("uninstalled units = %v, want netprobe service", uninstalled)
	}
	if _, exists := pl.installedSystemdAddons[agentnetprobe.DefaultSidecarName]; exists {
		t.Fatal("netprobe remained in installed systemd add-on state")
	}
}

func TestApplyConfigResponseAppliesLocalAddonsWithVisibilityConfig(t *testing.T) {
	dir := t.TempDir()
	override := `{
	  "addons": [
	    {
	      "addon_id": "powerdns",
	      "version": "0.1.0",
	      "enabled": true,
	      "binary_path": "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
	      "delivery": "os_package",
	      "supervision": "agent_sidecar",
	      "capabilities": ["native-telemetry:v1", "dns-activity", "powerdns-rpz"],
	      "config_json": {"listen_addr": "127.0.0.1:6000"}
	    }
	  ]
	}`
	if err := os.WriteFile(filepath.Join(dir, "addons.local.json"), []byte(override), 0o600); err != nil {
		t.Fatalf("write local add-on override: %v", err)
	}

	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	sidecarManager := &recordingSidecarLifecycleManager{started: true, attach: true}

	visibilityAppliedBeforeAddons := false
	addons := &recordingAddonManager{
		beforeApply: func() {
			visibilityAppliedBeforeAddons = sidecarManager.stopped
		},
	}
	pl := NewPushLoop(&Server{
		configDir:       dir,
		addonManager:    addons,
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  sidecarManager,
		sidecarStatus:   sidecarManager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)
	pl.setConfigVersion(testOldConfigVersion)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion:    testNewConfigVersion,
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
	}, "poll")

	if !ok {
		t.Fatal("applyConfigResponse() = false, want true")
	}
	if got := pl.getConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("config version = %q, want %s", got, testNewConfigVersion)
	}
	if len(addons.applied) != 1 {
		t.Fatalf("applied add-on specs = %d, want 1", len(addons.applied))
	}
	if !sidecarManager.stopped {
		t.Fatal("expected visibility config without a netprobe assignment to stop the attach manager")
	}
	if !visibilityAppliedBeforeAddons {
		t.Fatal("expected visibility bootstrap/lifecycle apply before native add-on reconciliation")
	}
	if got := addons.applied[0].ID; got != testPowerDNSAddonID {
		t.Fatalf("applied add-on ID = %q, want powerdns", got)
	}
	if got := addons.applied[0].BinaryPath; got != "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon" {
		t.Fatalf("applied binary path = %q", got)
	}
}

func TestApplyConfigResponseLocalOnlyNetprobeParticipatesInVisibilityGating(t *testing.T) {
	dir := t.TempDir()
	artifact := []byte("netprobe artifact must not be downloaded")
	override := `{
	  "addons": [
	    {
	      "addon_id": "netprobe",
	      "version": "1.0.0",
	      "enabled": true,
	      "binary_path": "/usr/local/lib/serviceradar/bin/serviceradar-netprobe",
	      "delivery": "pushed_artifact",
	      "supervision": "systemd_service",
	      "artifact_object_key": "native-addons/netprobe.tar.gz",
	      "artifact_sha256": "` + sha256Hex(artifact) + `",
	      "config_json": {"enabled": true}
	    }
	  ]
	}`
	if err := os.WriteFile(filepath.Join(dir, addonLocalOverrideFile), []byte(override), 0o600); err != nil {
		t.Fatalf("write local add-on override: %v", err)
	}

	store := &fakeObjectStore{data: map[string][]byte{"native-addons/netprobe.tar.gz": artifact}}
	manager := &recordingSidecarLifecycleManager{
		statuses: []sidecar.Status{{
			Name:       agentnetprobe.DefaultSidecarName,
			ConfigPath: filepath.Join(dir, "netprobe.json"),
		}},
		startAttachErr: errStartAttachTest,
	}
	pl := NewPushLoop(&Server{
		configDir:       dir,
		addonManager:    &recordingAddonManager{},
		objectStore:     store,
		netprobeSidecar: agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()}),
		sidecarManager:  manager,
		sidecarStatus:   manager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)
	pl.setConfigVersion(testOldConfigVersion)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion:    testNewConfigVersion,
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
	}, "poll")

	if ok {
		t.Fatal("applyConfigResponse() = true, want attach failure to defer the version")
	}
	if got := pl.getConfigVersion(); got != testOldConfigVersion {
		t.Fatalf("config version = %q, want %q after transient attach failure", got, testOldConfigVersion)
	}
	if manager.startAttachCalls != 1 {
		t.Fatalf("StartAttach calls = %d, want 1: visibility must consume the local systemd override", manager.startAttachCalls)
	}
	if store.downloads != 0 {
		t.Fatalf("netprobe artifact downloads = %d, want 0 while attach lifecycle is unavailable", store.downloads)
	}
}

func TestApplyAddonAssignmentsBlocksSystemdActivationAndAppliesSidecars(t *testing.T) {
	addOns := &recordingAddonManager{}
	pl := NewPushLoop(&Server{addonManager: addOns}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	disposition, err := pl.applyAddonAssignmentsWithActivationBlocks(
		context.Background(),
		[]*proto.AddonAssignmentConfig{
			{
				AddonId:     testNetprobeAddonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "systemd_service",
			},
			{
				AddonId:     testPowerDNSAddonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "agent_sidecar",
				BinaryPath:  "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
			},
		},
		map[string]bool{testNetprobeAddonID: true},
	)

	if disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyAddonAssignmentsWithActivationBlocks() = %v (%v), want succeeded", disposition, err)
	}
	if len(addOns.applied) != 1 || addOns.applied[0].ID != testPowerDNSAddonID {
		t.Fatalf("applied add-ons = %#v, want only powerdns", addOns.applied)
	}
}

func TestApplyConfigResponseBlocksNetprobeWhenVisibilityConfigIsMissing(t *testing.T) {
	addOns := &recordingAddonManager{}
	pl := NewPushLoop(&Server{addonManager: addOns}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)
	pl.setConfigVersion(testOldConfigVersion)

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: testNewConfigVersion,
		Addons: []*proto.AddonAssignmentConfig{
			{
				AddonId:     testNetprobeAddonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "systemd_service",
			},
			{
				AddonId:     testPowerDNSAddonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "agent_sidecar",
				BinaryPath:  "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
			},
		},
	}, "poll")

	if !ok {
		t.Fatal("applyConfigResponse() = false, want permanent visibility failure acknowledged")
	}
	if len(addOns.applied) != 1 || addOns.applied[0].ID != testPowerDNSAddonID {
		t.Fatalf("applied add-ons = %#v, want only powerdns", addOns.applied)
	}
	failure, exists := pl.configSectionFailureSnapshot()[configSectionVisibility]
	if !exists || failure.addonID != testNetprobeAddonID || failure.disposition != addonDeliveryPermanentFailure {
		t.Fatalf("visibility failure = %#v, want permanent netprobe failure", failure)
	}
	if _, exists := pl.configSectionFailureSnapshot()[configSectionAddons]; exists {
		t.Fatal("netprobe activation block must not fail the unrelated add-on section")
	}
}

func TestApplyConfigResponseSerializesVisibilityAndAddonActivation(t *testing.T) {
	addOns := &barrierAddonManager{
		firstApplyEntered: make(chan struct{}),
		releaseFirstApply: make(chan struct{}),
	}
	visibility := &barrierVisibilityManager{secondStopEntered: make(chan struct{})}
	pl := NewPushLoop(&Server{
		addonManager:    addOns,
		netprobeSidecar: agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()}),
		sidecarManager:  visibility,
		sidecarStatus:   visibility,
	}, nil, 30*time.Second, logger.NewTestLogger())

	response := func(version string, timestamp int64) *proto.AgentConfigResponse {
		return &proto.AgentConfigResponse{
			ConfigVersion:   version,
			ConfigTimestamp: timestamp,
			VisibilityConfig: &proto.VisibilityConfig{
				Enabled: true,
			},
			Addons: []*proto.AddonAssignmentConfig{{
				AddonId:     testPowerDNSAddonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "agent_sidecar",
				BinaryPath:  "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
			}},
		}
	}

	firstDone := make(chan bool, 1)
	go func() {
		firstDone <- pl.applyConfigResponse(context.Background(), response("v1", 100), "poll")
	}()

	select {
	case <-addOns.firstApplyEntered:
	case <-time.After(time.Second):
		t.Fatal("first response did not reach add-on activation")
	}

	secondStarted := make(chan struct{})
	secondDone := make(chan bool, 1)
	go func() {
		close(secondStarted)
		secondDone <- pl.applyConfigResponse(context.Background(), response("v2", 101), "control")
	}()
	<-secondStarted

	select {
	case <-visibility.secondStopEntered:
		t.Fatal("second response interleaved visibility while first response was activating add-ons")
	case <-time.After(100 * time.Millisecond):
	}

	close(addOns.releaseFirstApply)
	if !<-firstDone {
		t.Fatal("first apply failed")
	}
	if !<-secondDone {
		t.Fatal("second apply failed")
	}

	select {
	case <-visibility.secondStopEntered:
	case <-time.After(time.Second):
		t.Fatal("second response did not continue after first response transaction completed")
	}
	if got := pl.getConfigVersion(); got != "v2" {
		t.Fatalf("config version = %q, want v2", got)
	}
}

func TestApplyConfigResponseRejectsDelayedOlderRequestSequence(t *testing.T) {
	newerApplyEntered := make(chan struct{})
	releaseNewerApply := make(chan struct{})
	var applyStarts atomic.Int32
	addOns := &recordingAddonManager{beforeApply: func() {
		if applyStarts.Add(1) == 1 {
			close(newerApplyEntered)
			<-releaseNewerApply
		}
	}}
	pl := NewPushLoop(&Server{addonManager: addOns}, nil, 30*time.Second, logger.NewTestLogger())

	makeResponse := func(version string, timestamp int64, addonID string) *proto.AgentConfigResponse {
		return &proto.AgentConfigResponse{
			ConfigVersion:   version,
			ConfigTimestamp: timestamp,
			Addons: []*proto.AddonAssignmentConfig{{
				AddonId:     addonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "agent_sidecar",
				BinaryPath:  "/usr/local/lib/serviceradar/bin/" + addonID,
			}},
		}
	}

	newerDone := make(chan bool, 1)
	go func() {
		newerDone <- pl.applyConfigResponseWithSequence(
			context.Background(),
			makeResponse("newer", 199, "new-addon"),
			"control",
			2,
		)
	}()

	select {
	case <-newerApplyEntered:
	case <-time.After(time.Second):
		t.Fatal("newer config did not begin its apply transaction")
	}

	olderStarted := make(chan struct{})
	olderDone := make(chan bool, 1)
	go func() {
		close(olderStarted)
		olderDone <- pl.applyConfigResponseWithSequence(
			context.Background(),
			makeResponse("older", 200, "old-addon"),
			"poll",
			1,
		)
	}()
	<-olderStarted

	close(releaseNewerApply)
	if !<-newerDone {
		t.Fatal("newer config apply failed")
	}
	if <-olderDone {
		t.Fatal("stale config response was accepted")
	}
	if got := pl.getConfigVersion(); got != "newer" {
		t.Fatalf("config version = %q, want newer after stale response", got)
	}
	if addOns.applyCalls != 1 {
		t.Fatalf("add-on applies = %d, want 1; stale response must not enter the pipeline", addOns.applyCalls)
	}
	if len(addOns.applied) != 1 || addOns.applied[0].ID != "new-addon" {
		t.Fatalf("applied add-ons = %#v, want only the newer response", addOns.applied)
	}
}

func TestApplyConfigResponseAcceptsLaterSequenceDespiteOlderTimestamp(t *testing.T) {
	addOns := &recordingAddonManager{}
	pl := NewPushLoop(&Server{addonManager: addOns}, nil, 30*time.Second, logger.NewTestLogger())

	makeResponse := func(version string, timestamp int64, addonID string) *proto.AgentConfigResponse {
		return &proto.AgentConfigResponse{
			ConfigVersion:   version,
			ConfigTimestamp: timestamp,
			Addons: []*proto.AddonAssignmentConfig{{
				AddonId:     addonID,
				Enabled:     true,
				Delivery:    "os_package",
				Supervision: "agent_sidecar",
				BinaryPath:  "/usr/local/lib/serviceradar/bin/" + addonID,
			}},
		}
	}

	if !pl.applyConfigResponseWithSequence(
		context.Background(),
		makeResponse("first", 250, "first-addon"),
		"poll",
		1,
	) {
		t.Fatal("initial config apply failed")
	}
	if !pl.applyConfigResponseWithSequence(
		context.Background(),
		makeResponse("later", 249, "later-addon"),
		"control",
		2,
	) {
		t.Fatal("later request sequence was rejected because of an older wall-clock timestamp")
	}
	if got := pl.getConfigVersion(); got != "later" {
		t.Fatalf("config version = %q, want later", got)
	}
	if addOns.applyCalls != 2 {
		t.Fatalf("add-on applies = %d, want 2", addOns.applyCalls)
	}
}

func TestApplyConfigResponseRetriesFromLaterRequestAfterTransientFailure(t *testing.T) {
	addOns := &failOnceAddonManager{}
	pl := NewPushLoop(&Server{addonManager: addOns}, nil, 30*time.Second, logger.NewTestLogger())
	pl.setConfigVersion(testOldConfigVersion)
	response := &proto.AgentConfigResponse{
		ConfigVersion:   testNewConfigVersion,
		ConfigTimestamp: 300,
		Addons: []*proto.AddonAssignmentConfig{{
			AddonId:     testPowerDNSAddonID,
			Enabled:     true,
			Delivery:    "os_package",
			Supervision: "agent_sidecar",
			BinaryPath:  "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
		}},
	}

	if pl.applyConfigResponseWithSequence(context.Background(), response, "control", 1) {
		t.Fatal("first apply = true, want transient supervisor failure")
	}
	if !pl.applyConfigResponseWithSequence(context.Background(), response, "poll", 2) {
		t.Fatal("retry from a later request was rejected")
	}
	if got := addOns.calls.Load(); got != 2 {
		t.Fatalf("add-on applies = %d, want 2", got)
	}
	if got := pl.getConfigVersion(); got != testNewConfigVersion {
		t.Fatalf("config version = %q, want %q after retry", got, testNewConfigVersion)
	}
}
