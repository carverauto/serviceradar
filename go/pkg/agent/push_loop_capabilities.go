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

package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
)

const (
	capabilityHostNetworkVisibility                       = "host-network-visibility"
	capabilityHostNetworkVisibilityFingerprintEnabled     = "host-network-visibility.fingerprint.enabled"
	capabilityHostNetworkVisibilityFingerprintUnavailable = "host-network-visibility.fingerprint.unavailable"
	capabilityHostNetworkVisibilityDPIUnavailable         = "host-network-visibility.dpi.unavailable"
	capabilityHostNetworkVisibilityFlowUnavailable        = "host-network-visibility.flow_attribution.unavailable"
	capabilityHostNetworkVisibilitySnapshotUnavailable    = "host-network-visibility.process_snapshot.unavailable"
	capabilityAddonNativeHost                             = "addon.native.host"
	capabilityAddonNativeHostUnavailable                  = "addon.native.host.unavailable"
	capabilitySweepBannerGrab                             = "sweep.banner_grab"
	capabilitySweepBannerGrabAvailable                    = "sweep.banner_grab.available"
	capabilitySweepBannerGrabUnavailable                  = "sweep.banner_grab.unavailable"
	pluginHostAuthorityCapabilityV1                       = "plugin-host-authority:v1"
	proxmoxSemanticConnectorCapabilityV1                  = "proxmox-semantic-connector:v1"
	proxmoxConsolePolicyBindingCapabilityV1               = "proxmox-console-policy-binding:v1"
	proxmoxIdentityCapabilityV3                           = "proxmox-identity:v3"

	agentCapabilityServiceName = "agent"
	agentCapabilityServiceType = "agent"
)

const (
	capabilityStatusAvailable              = "available"
	capabilityStatusUnavailable            = "unavailable"
	capabilityReasonNoEnabledSweepProfile  = "no_enabled_sweep_profile"
	capabilityReasonNetprobeUnavailable    = "netprobe_unavailable"
	capabilityReasonRecogCorpusUnavailable = "recog_corpus_unavailable"

	// systemdUnitFailed is systemd's ActiveState=failed and Result=failed value.
	systemdUnitFailed = "failed"
)

type capabilityStatusPayload struct {
	Status string `json:"status"`
	Reason string `json:"reason,omitempty"`
}

type hostNetworkVisibilityCapabilityStatus struct {
	Fingerprint     string                         `json:"fingerprint"`
	DPI             string                         `json:"dpi"`
	FlowAttribution string                         `json:"flow_attribution"`
	ProcessSnapshot string                         `json:"process_snapshot"`
	RunningAsRoot   bool                           `json:"running_as_root,omitempty"`
	CorpusRevisions *agentnetprobe.CorpusRevisions `json:"corpus_revisions,omitempty"`
}

type sweepCapabilityStatus struct {
	BannerGrab capabilityStatusPayload `json:"banner_grab"`
}

type remoteCaptureStatus struct {
	Active       bool `json:"active"`
	SessionCount int  `json:"session_count"`
}

type agentCapabilityStatusPayload struct {
	Capabilities          []string                              `json:"capabilities"`
	HostNetworkVisibility hostNetworkVisibilityCapabilityStatus `json:"host_network_visibility"`
	Sweep                 sweepCapabilityStatus                 `json:"sweep"`
	RemoteCapture         remoteCaptureStatus                   `json:"remote_capture"`
	Sidecars              []*proto.SidecarStatus                `json:"sidecars,omitempty"`
}

func (p *PushLoop) buildAgentCapabilityGatewayStatus(
	cfg *ServerConfig,
	sidecarStatus sidecarStatusProvider,
	addonManager agentaddon.AddonManager,
) *proto.GatewayServiceStatus {
	sidecars := sidecarStatusesForStatus(sidecarStatus)

	var addonStatuses []agentaddon.Status
	if addonManager != nil {
		addonStatuses = addonManager.Status()
	}
	sidecars = append(sidecars, agentaddon.ToProtoStatuses(addonStatuses)...)
	sidecars = append(sidecars, p.systemdAddonStatuses(resolveAddonArtifactRoot(""), sidecars)...)
	// Surface add-ons whose pushed-artifact delivery failed permanently (404, sha
	// mismatch, bad signature, …) so the control plane shows the failure instead of the
	// add-on silently vanishing. Skip any add-on that already has a real status entry
	// (a last-known-good process still running keeps reporting its actual state).
	sidecars = append(sidecars, p.addonDeliveryFailureStatuses(sidecars)...)
	// Surface add-ons whose CONFIG section permanently fails to apply (e.g. netprobe
	// running on bootstrap-only config after a type-invalid config_json) as unhealthy —
	// unlike delivery failures this overrides a running entry, because the process is
	// alive but configured wrong.
	sidecars = append(sidecars, p.configApplyFailureStatuses(sidecars)...)

	corpusRevisions := p.netprobeCorpusRevisions()
	sweepBannerGrab := p.sweepBannerGrabCapabilityStatus(sidecars, corpusRevisions)
	capabilities := getAgentCapabilitiesForSidecarsWithRDPPath(
		cfg,
		sidecars,
		sweepBannerGrab.Status == capabilityStatusAvailable,
		p.remoteAccessRDPAdapterPath(),
	)
	capabilities = append(capabilities, addonCapabilities(addonStatuses)...)

	resp := buildAgentCapabilityStatusResponse(
		capabilities,
		sidecars,
		p.netprobeRunningAsRoot(),
		corpusRevisions,
		sweepBannerGrab,
		p.netprobeActiveCaptureCount(),
	)
	return p.convertToGatewayStatus(resp, agentCapabilityServiceName, agentCapabilityServiceType)
}

func buildAgentCapabilityStatusResponse(
	capabilities []string,
	sidecars []*proto.SidecarStatus,
	runningAsRoot bool,
	corpusRevisions agentnetprobe.CorpusRevisions,
	sweepBannerGrab capabilityStatusPayload,
	activeCaptureCount int,
) *proto.StatusResponse {
	corpusRevisionPayload := &corpusRevisions
	if corpusRevisions == (agentnetprobe.CorpusRevisions{}) {
		corpusRevisionPayload = nil
	}

	payload, err := json.Marshal(agentCapabilityStatusPayload{
		Capabilities: append([]string(nil), capabilities...),
		HostNetworkVisibility: hostNetworkVisibilityCapabilityStatus{
			Fingerprint:     hostNetworkVisibilityFingerprintStatus(capabilities),
			DPI:             "unavailable",
			FlowAttribution: "unavailable",
			ProcessSnapshot: "unavailable",
			RunningAsRoot:   runningAsRoot,
			CorpusRevisions: corpusRevisionPayload,
		},
		Sweep: sweepCapabilityStatus{
			BannerGrab: sweepBannerGrab,
		},
		RemoteCapture: remoteCaptureStatus{
			Active:       activeCaptureCount > 0,
			SessionCount: activeCaptureCount,
		},
		Sidecars: sidecars,
	})
	if err != nil {
		payload = []byte(`{"error":"agent capability status marshal failed"}`)
	}

	return &proto.StatusResponse{
		Available:   true,
		Message:     payload,
		ServiceName: agentCapabilityServiceName,
		ServiceType: agentCapabilityServiceType,
	}
}

func agentCapabilitiesForStatusWithBannerGrab(
	cfg *ServerConfig,
	sidecars []*proto.SidecarStatus,
	sweepBannerGrabAvailable bool,
) []string {
	return getAgentCapabilitiesForSidecars(cfg, sidecars, sweepBannerGrabAvailable)
}

func sidecarStatusesForStatus(provider sidecarStatusProvider) []*proto.SidecarStatus {
	if provider == nil {
		return nil
	}

	return sidecar.ToProtoStatuses(provider.Status())
}

type agentCapabilityOptions struct {
	enhancedBPF                             bool
	desktopRDP                              bool
	hostNetworkVisibilitySupported          bool
	hostNetworkVisibilityFingerprintEnabled bool
	nativeAddonHost                         bool
	sweepBannerGrabAvailable                bool
	bumblebee                               bool
	endpointInventory                       bool
	icmpAvailable                           bool
	mtrAvailable                            bool
}

func getAgentCapabilities(cfg *ServerConfig) []string {
	return getAgentCapabilitiesForSidecars(cfg, nil, false)
}

func (p *PushLoop) getAgentCapabilities(cfg *ServerConfig) []string {
	if p == nil || p.server == nil {
		return getAgentCapabilities(cfg)
	}

	p.server.mu.RLock()
	sidecarStatus := p.server.sidecarStatus
	p.server.mu.RUnlock()

	return getAgentCapabilitiesForSidecars(cfg, sidecarStatusesForStatus(sidecarStatus), false)
}

func (p *PushLoop) netprobeRunningAsRoot() bool {
	if p == nil || p.server == nil {
		return false
	}

	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	p.server.mu.RUnlock()
	if netprobeSidecar == nil {
		return false
	}

	return netprobeSidecar.RunningAsRoot()
}

func (p *PushLoop) netprobeCorpusRevisions() agentnetprobe.CorpusRevisions {
	if p == nil || p.server == nil {
		return agentnetprobe.CorpusRevisions{}
	}

	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	p.server.mu.RUnlock()
	if netprobeSidecar == nil {
		return agentnetprobe.CorpusRevisions{}
	}

	return netprobeSidecar.CorpusRevisions()
}

func (p *PushLoop) netprobeActiveCaptureCount() int {
	if p == nil || p.server == nil {
		return 0
	}

	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	p.server.mu.RUnlock()
	if netprobeSidecar == nil {
		return 0
	}

	return netprobeSidecar.ActiveCaptureCount()
}

func (p *PushLoop) sweepBannerGrabCapabilityStatus(
	sidecars []*proto.SidecarStatus,
	corpusRevisions agentnetprobe.CorpusRevisions,
) capabilityStatusPayload {
	if p == nil || p.server == nil || !p.server.BannerGrabEnabled() {
		return capabilityStatusPayload{
			Status: capabilityStatusUnavailable,
			Reason: capabilityReasonNoEnabledSweepProfile,
		}
	}
	if !hasHealthyNetprobeSidecar(sidecars) {
		return capabilityStatusPayload{
			Status: capabilityStatusUnavailable,
			Reason: capabilityReasonNetprobeUnavailable,
		}
	}
	if !corpusRevisions.RecogCorpusLoaded {
		return capabilityStatusPayload{
			Status: capabilityStatusUnavailable,
			Reason: capabilityReasonRecogCorpusUnavailable,
		}
	}

	return capabilityStatusPayload{Status: capabilityStatusAvailable}
}

func getAgentCapabilitiesForSidecars(
	cfg *ServerConfig,
	sidecars []*proto.SidecarStatus,
	sweepBannerGrabAvailable bool,
) []string {
	return getAgentCapabilitiesForSidecarsWithRDPPath(
		cfg,
		sidecars,
		sweepBannerGrabAvailable,
		remoteAccessRDPAdapterPathFromConfig(cfg),
	)
}

func getAgentCapabilitiesForSidecarsWithRDPPath(
	cfg *ServerConfig,
	sidecars []*proto.SidecarStatus,
	sweepBannerGrabAvailable bool,
	rdpAdapterPath string,
) []string {
	icmpAvailable, mtrAvailable := probeICMPAndMTRSockets()
	return agentCapabilities(agentCapabilityOptions{
		enhancedBPF:                             remoteaccess.PlatformEnhancedRecordingAvailable(),
		desktopRDP:                              remoteAccessRDPCapabilityEnabledAtPath(cfg, rdpAdapterPath),
		hostNetworkVisibilitySupported:          supportsHostNetworkVisibility(runtime.GOOS, detectDeploymentType()),
		nativeAddonHost:                         runtimeSupportsNativeAddonHosting(),
		hostNetworkVisibilityFingerprintEnabled: hasHealthyNetprobeSidecar(sidecars),
		sweepBannerGrabAvailable:                sweepBannerGrabAvailable,
		bumblebee:                               cfg != nil && cfg.Bumblebee != nil && cfg.Bumblebee.Enabled,
		endpointInventory:                       cfg != nil && cfg.EndpointInventory != nil && cfg.EndpointInventory.Enabled,
		icmpAvailable:                           icmpAvailable,
		mtrAvailable:                            mtrAvailable,
	})
}

func agentCapabilities(options agentCapabilityOptions) []string {
	capabilities := make([]string, 0, 24)
	if options.icmpAvailable {
		capabilities = append(capabilities, "icmp")
	}
	if options.mtrAvailable {
		capabilities = append(capabilities, "mtr")
	}
	capabilities = append(capabilities,
		sweepType,
		commandTypeAdhocScan,
		"snmp",
		"mapper",
		"sync",
		"sysmon",
		remoteaccess.CapabilityRemoteAccess,
		remoteaccess.CapabilityRemoteAccessSSH,
		remoteaccess.CapabilityRemoteAccessApp,
		remoteaccess.CapabilityRemoteAccessTCP,
		remoteaccess.CapabilityRemoteAccessFile,
		remoteaccess.CapabilityRemoteAccessSFTP,
		remoteaccess.CapabilityRemoteAccessRecording,
		pluginHostAuthorityCapabilityV1,
		pluginResultRetainedDeliveryCapabilityV1,
		proxmoxSemanticConnectorCapabilityV1,
		proxmoxConsolePolicyBindingCapabilityV1,
		proxmoxIdentityCapabilityV3,
	)
	if options.hostNetworkVisibilitySupported {
		capabilities = append(capabilities, capabilityHostNetworkVisibility)
	}
	capabilities = append(capabilities,
		capabilityHostNetworkVisibilityDPIUnavailable,
		capabilityHostNetworkVisibilityFlowUnavailable,
		capabilityHostNetworkVisibilitySnapshotUnavailable,
		capabilitySweepBannerGrab,
	)

	if options.hostNetworkVisibilityFingerprintEnabled {
		capabilities = append(capabilities, capabilityHostNetworkVisibilityFingerprintEnabled)
	} else {
		capabilities = append(capabilities, capabilityHostNetworkVisibilityFingerprintUnavailable)
	}
	if options.sweepBannerGrabAvailable {
		capabilities = append(capabilities, capabilitySweepBannerGrabAvailable)
	} else {
		capabilities = append(capabilities, capabilitySweepBannerGrabUnavailable)
	}

	// Reported as an explicit pair. A containerized agent installs no native add-on
	// at all (applyAddonAssignments returns early), so the control plane must be told
	// outright rather than left to infer it from deployment type -- otherwise it keeps
	// such an agent in rollout target sets where it can never report health.
	if options.nativeAddonHost {
		capabilities = append(capabilities, capabilityAddonNativeHost)
	} else {
		capabilities = append(capabilities, capabilityAddonNativeHostUnavailable)
	}

	if options.bumblebee {
		capabilities = append(capabilities, "bumblebee")
	}
	if options.endpointInventory {
		capabilities = append(capabilities, "endpoint-inventory")
	}

	if options.enhancedBPF {
		capabilities = append(capabilities, remoteaccess.CapabilityRemoteAccessBPF)
	}
	if options.desktopRDP {
		capabilities = append(
			capabilities,
			remoteaccess.CapabilityRemoteAccessDesktop,
			remoteaccess.CapabilityRemoteAccessRDP,
		)
	}

	return capabilities
}

func probeICMPAndMTRSockets() (icmpOK bool, mtrOK bool) {
	sock, err := mtr.NewRawSocket(false)
	if err != nil {
		return false, false
	}
	if closeErr := sock.Close(); closeErr != nil {
		return false, false
	}

	return true, true
}

func hostNetworkVisibilityFingerprintStatus(capabilities []string) string {
	if containsCapability(capabilities, capabilityHostNetworkVisibilityFingerprintEnabled) {
		return "enabled"
	}

	return "unavailable"
}

type systemdUnitStatus struct {
	state     agentaddon.State
	pid       int
	lastError string
}

// systemdAddonStatuses synthesizes `addon:<id>` entries so systemd-managed native
// add-ons land in the control-plane AddonStatus read model. These add-ons are not
// supervised by the go-plugin add-on manager, so they otherwise have no `addon:` status.
// The installed version comes from the activation `current` symlink (target
// `versions/<version>`). For add-ons that also expose a sidecar/IPC status such as
// netprobe, the richer sidecar state is folded in; standalone services such as
// workload-identity use systemd active state and MainPID.
func (p *PushLoop) systemdAddonStatuses(root string, sidecars []*proto.SidecarStatus) []*proto.SidecarStatus {
	if root == "" {
		root = resolveAddonArtifactRoot("")
	}

	p.systemdRehydrateOnce.Do(func() {
		p.rehydrateSystemdAddonsFromRoot(root)
	})

	installed := p.systemdAddonSnapshot()
	if len(installed) == 0 {
		return nil
	}

	ids := make([]string, 0, len(installed))
	for id := range installed {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	statuses := make([]agentaddon.Status, 0, len(ids))
	for _, id := range ids {
		st := p.systemdAddonStatus(root, id, installed[id], sidecars)
		if st.ID != "" {
			statuses = append(statuses, st)
		}
	}

	return agentaddon.ToProtoStatuses(statuses)
}

// netprobeAddonStatus is retained for focused tests and legacy call sites; the
// production path uses systemdAddonStatuses for every installed systemd add-on.
func (p *PushLoop) netprobeAddonStatus(root string, sidecars []*proto.SidecarStatus) *proto.SidecarStatus {
	id := agentnetprobe.DefaultSidecarName
	units := p.systemdAddonUnits(id)
	if len(units) == 0 {
		return nil
	}

	st := p.systemdAddonStatus(root, id, units, sidecars)
	out := agentaddon.ToProtoStatuses([]agentaddon.Status{st})
	if len(out) == 0 {
		return nil
	}

	return out[0]
}

func (p *PushLoop) systemdAddonSnapshot() map[string][]string {
	p.systemdAddonsMu.Lock()
	defer p.systemdAddonsMu.Unlock()

	if len(p.installedSystemdAddons) == 0 {
		return nil
	}

	out := make(map[string][]string, len(p.installedSystemdAddons))
	for id, units := range p.installedSystemdAddons {
		out[id] = append([]string(nil), units...)
	}

	return out
}

func (p *PushLoop) systemdAddonStatus(root, id string, units []string, sidecars []*proto.SidecarStatus) agentaddon.Status {
	st := agentaddon.Status{
		ID:    id,
		State: agentaddon.StateStopped,
		Arch:  runtime.GOARCH,
	}
	if target, ok := readAddonCurrentTarget(filepath.Join(root, id)); ok {
		st.Version = filepath.Base(target)
	}

	foldedSidecar := foldSidecarStatus(&st, id, sidecars)
	if foldedSidecar && st.PID > 0 {
		return st
	}

	status := systemdAddonUnitStatusWithReader(units, p.readSystemdAddonUnitStatus)
	if !foldedSidecar {
		st.State = status.state
		st.LastError = status.lastError
	}
	if st.PID <= 0 {
		st.PID = status.pid
	}
	if st.LastError == "" {
		st.LastError = status.lastError
	}
	if st.LastHealthAt.IsZero() && status.state == agentaddon.StateRunning {
		st.LastHealthAt = time.Now().UTC()
	}

	return st
}

func foldSidecarStatus(st *agentaddon.Status, id string, sidecars []*proto.SidecarStatus) bool {
	for _, s := range sidecars {
		if s == nil || !strings.EqualFold(s.GetName(), id) {
			continue
		}

		st.State = agentaddon.State(s.GetState())
		st.PID = int(s.GetPid())
		st.RestartCount = int(s.GetRestartCount())
		st.LastError = s.GetLastError()
		if s.GetLastHealthAt() > 0 {
			st.LastHealthAt = time.Unix(0, s.GetLastHealthAt()).UTC()
		}

		return true
	}

	return false
}

func (p *PushLoop) readSystemdAddonUnitStatus(unit string) systemdUnitStatus {
	if p != nil && p.readSystemdUnitStatus != nil {
		return p.readSystemdUnitStatus(unit)
	}

	return readSystemdUnitStatusDefault(unit)
}

func systemdAddonUnitStatusWithReader(
	units []string,
	readUnitStatus func(string) systemdUnitStatus,
) systemdUnitStatus {
	if len(units) == 0 {
		return systemdUnitStatus{state: agentaddon.StateStopped}
	}

	// A timer is the cadence owner for timer-supervised add-ons. Prefer its
	// health over a backing oneshot service, whose most recent successful run is
	// normally inactive and whose transient activity must not mask an elapsed
	// timer with no future trigger.
	timerUnits := make([]string, 0, len(units))
	serviceUnits := make([]string, 0, len(units))
	for _, unit := range units {
		if strings.HasSuffix(strings.TrimSpace(unit), ".timer") {
			timerUnits = append(timerUnits, unit)
		} else {
			serviceUnits = append(serviceUnits, unit)
		}
	}
	if len(timerUnits) > 0 {
		timerStatus := systemdTimerUnitStatusWithReader(timerUnits, readUnitStatus)
		if timerStatus.state != agentaddon.StateRunning {
			return timerStatus
		}

		// An inactive oneshot service is expected between timer firings. A failed
		// service is not: preserve that failure instead of letting the healthy
		// timer hide it. An active service contributes the in-flight scan PID.
		for _, unit := range serviceUnits {
			status := readUnitStatus(unit)
			if status.state == agentaddon.StateUnhealthy {
				return status
			}
			if status.state == agentaddon.StateRunning && status.pid > 0 {
				timerStatus.pid = status.pid
			}
		}

		return timerStatus
	}

	best := systemdUnitStatus{state: agentaddon.StateStopped}
	for _, unit := range units {
		status := readUnitStatus(unit)
		switch status.state {
		case agentaddon.StateRunning:
			return status
		case agentaddon.StateStarting, agentaddon.StateRestarting:
			best = status
		case agentaddon.StateDegraded:
			// Not produced here: these states come from parsing `systemctl show`,
			// and degraded is an add-on HEALTH concept the unit view never sees.
			// Handled explicitly anyway, because a degraded add-on is running --
			// so if it ever does reach this path it must outrank every
			// not-running state rather than falling through as unknown.
			if best.state != agentaddon.StateRunning {
				best = status
			}
		case agentaddon.StateUnhealthy:
			if best.state == agentaddon.StateStopped {
				best = status
			}
		case agentaddon.StateStopped, agentaddon.StateCircuitOpen:
			if best.state == agentaddon.StateStopped {
				best = status
			}
		}
	}

	return best
}

func systemdTimerUnitStatusWithReader(
	units []string,
	readUnitStatus func(string) systemdUnitStatus,
) systemdUnitStatus {
	best := systemdUnitStatus{state: agentaddon.StateStopped}
	for _, unit := range units {
		status := readUnitStatus(unit)
		switch status.state {
		case agentaddon.StateUnhealthy, agentaddon.StateCircuitOpen:
			return status
		case agentaddon.StateRunning:
			best = status
		case agentaddon.StateDegraded:
			// See the note in the service variant: unreachable from systemd
			// parsing, but degraded means running, so it outranks anything that
			// is not running.
			if best.state != agentaddon.StateRunning {
				best = status
			}
		case agentaddon.StateStarting, agentaddon.StateRestarting:
			if best.state != agentaddon.StateRunning {
				best = status
			}
		case agentaddon.StateStopped:
			if best.state == agentaddon.StateStopped {
				best = status
			}
		}
	}

	return best
}

func readSystemdUnitStatusDefault(unit string) systemdUnitStatus {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	cmd := exec.CommandContext(
		ctx,
		"systemctl",
		"show",
		"--property=ActiveState",
		"--property=SubState",
		"--property=MainPID",
		"--property=Result",
		"--property=ExecMainStatus",
		"--property=NextElapseUSecRealtime",
		"--property=NextElapseUSecMonotonic",
		unit,
	)
	out, err := cmd.Output()
	if err != nil {
		return systemdUnitStatus{
			state:     agentaddon.StateUnhealthy,
			lastError: fmt.Sprintf("systemctl show %s failed: %v", unit, err),
		}
	}

	return parseSystemdUnitStatusOutputForUnit(unit, string(out))
}

func parseSystemdUnitStatusOutput(out string) systemdUnitStatus {
	return parseSystemdUnitStatusOutputForUnit("", out)
}

func parseSystemdUnitStatusOutputForUnit(unit string, out string) systemdUnitStatus {
	activeState := ""
	subState := ""
	nextRealtime := ""
	nextMonotonic := ""
	result := ""
	execMainStatus := ""
	pid := 0

	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}

		switch strings.TrimSpace(key) {
		case "ActiveState":
			activeState = strings.TrimSpace(value)
		case "SubState":
			subState = strings.TrimSpace(value)
		case "Result":
			result = strings.TrimSpace(value)
		case "ExecMainStatus":
			execMainStatus = strings.TrimSpace(value)
		case "MainPID":
			if parsed, parseErr := strconv.Atoi(strings.TrimSpace(value)); parseErr == nil && parsed > 0 {
				pid = parsed
			}
		case "NextElapseUSecRealtime":
			nextRealtime = strings.TrimSpace(value)
		case "NextElapseUSecMonotonic":
			nextMonotonic = strings.TrimSpace(value)
		}
	}
	if strings.HasSuffix(strings.TrimSpace(unit), ".timer") && activeState == "active" {
		if subState != "waiting" && subState != "running" {
			reportedSubState := subState
			if reportedSubState == "" {
				reportedSubState = "unknown"
			}
			return systemdUnitStatus{
				state:     agentaddon.StateUnhealthy,
				pid:       pid,
				lastError: fmt.Sprintf("systemd timer is %s with no scheduled trigger", reportedSubState),
			}
		}
		if subState == "waiting" && !finiteSystemdTimerNext(nextRealtime) && !finiteSystemdTimerNext(nextMonotonic) {
			return systemdUnitStatus{
				state:     agentaddon.StateUnhealthy,
				pid:       pid,
				lastError: "systemd timer has no finite next trigger",
			}
		}
	}

	switch activeState {
	case "active":
		return systemdUnitStatus{state: agentaddon.StateRunning, pid: pid}
	case "activating":
		return systemdUnitStatus{state: agentaddon.StateStarting, pid: pid}
	case "deactivating", "reloading":
		return systemdUnitStatus{state: agentaddon.StateRestarting, pid: pid}
	case systemdUnitFailed:
		return systemdUnitStatus{
			state:     agentaddon.StateUnhealthy,
			pid:       pid,
			lastError: systemdFailedUnitError(result, execMainStatus),
		}
	default:
		return systemdUnitStatus{state: agentaddon.StateStopped, pid: pid}
	}
}

func systemdFailedUnitError(result, execMainStatus string) string {
	detail := "systemd unit failed"
	if result != "" && result != systemdUnitFailed {
		detail += ": result=" + result
	}
	if execMainStatus != "" && execMainStatus != "0" {
		if strings.Contains(detail, "result=") {
			detail += " status=" + execMainStatus
		} else {
			detail += ": status=" + execMainStatus
		}
	}

	return detail
}

func finiteSystemdTimerNext(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "infinity", "n/a":
		return false
	default:
		return true
	}
}

func hasHealthyNetprobeSidecar(sidecars []*proto.SidecarStatus) bool {
	for _, status := range sidecars {
		if status == nil {
			continue
		}
		if strings.EqualFold(status.GetName(), "netprobe") && status.GetState() == string(sidecar.StateRunning) {
			return true
		}
	}

	return false
}

func containsCapability(capabilities []string, capability string) bool {
	for _, candidate := range capabilities {
		if candidate == capability {
			return true
		}
	}

	return false
}

func remoteAccessRDPCapabilityEnabled(cfg *ServerConfig) bool {
	return remoteAccessRDPCapabilityEnabledAtPath(cfg, remoteAccessRDPAdapterPathFromConfig(cfg))
}

func remoteAccessRDPCapabilityEnabledAtPath(cfg *ServerConfig, adapterPath string) bool {
	if cfg == nil || cfg.RemoteAccessRDPEnabled == nil || !*cfg.RemoteAccessRDPEnabled {
		return false
	}

	return remoteaccess.RDPAdapterReady(adapterPath)
}

func remoteAccessRDPAdapterPathFromConfig(cfg *ServerConfig) string {
	if cfg == nil {
		return ""
	}

	return strings.TrimSpace(cfg.RemoteAccessRDPAdapterPath)
}
