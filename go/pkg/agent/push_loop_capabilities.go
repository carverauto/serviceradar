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
	"github.com/carverauto/serviceradar/proto"
)

const (
	maxSysmonStatusPayloadBytes = 8 * 1024 * 1024

	capabilityHostNetworkVisibility                       = "host-network-visibility"
	capabilityHostNetworkVisibilityFingerprintEnabled     = "host-network-visibility.fingerprint.enabled"
	capabilityHostNetworkVisibilityFingerprintUnavailable = "host-network-visibility.fingerprint.unavailable"
	capabilityHostNetworkVisibilityDPIUnavailable         = "host-network-visibility.dpi.unavailable"
	capabilityHostNetworkVisibilityFlowUnavailable        = "host-network-visibility.flow_attribution.unavailable"
	capabilityHostNetworkVisibilitySnapshotUnavailable    = "host-network-visibility.process_snapshot.unavailable"
	capabilitySweepBannerGrab                             = "sweep.banner_grab"
	capabilitySweepBannerGrabAvailable                    = "sweep.banner_grab.available"
	capabilitySweepBannerGrabUnavailable                  = "sweep.banner_grab.unavailable"

	agentCapabilityServiceName = "agent"
	agentCapabilityServiceType = "agent"
)

const (
	capabilityStatusAvailable              = "available"
	capabilityStatusUnavailable            = "unavailable"
	capabilityReasonNoEnabledSweepProfile  = "no_enabled_sweep_profile"
	capabilityReasonNetprobeUnavailable    = "netprobe_unavailable"
	capabilityReasonRecogCorpusUnavailable = "recog_corpus_unavailable"
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

type agentCapabilityStatusPayload struct {
	Capabilities          []string                              `json:"capabilities"`
	HostNetworkVisibility hostNetworkVisibilityCapabilityStatus `json:"host_network_visibility"`
	Sweep                 sweepCapabilityStatus                 `json:"sweep"`
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

	corpusRevisions := p.netprobeCorpusRevisions()
	sweepBannerGrab := p.sweepBannerGrabCapabilityStatus(sidecars, corpusRevisions)
	capabilities := agentCapabilitiesForStatusWithBannerGrab(cfg, sidecars, sweepBannerGrab.Status == capabilityStatusAvailable)
	capabilities = append(capabilities, addonCapabilities(addonStatuses)...)

	resp := buildAgentCapabilityStatusResponse(
		capabilities,
		sidecars,
		p.netprobeRunningAsRoot(),
		corpusRevisions,
		sweepBannerGrab,
	)
	return p.convertToGatewayStatus(resp, agentCapabilityServiceName, agentCapabilityServiceType)
}

func buildAgentCapabilityStatusResponse(
	capabilities []string,
	sidecars []*proto.SidecarStatus,
	runningAsRoot bool,
	corpusRevisions agentnetprobe.CorpusRevisions,
	sweepBannerGrab capabilityStatusPayload,
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
	hostNetworkVisibilityFingerprintEnabled bool
	sweepBannerGrabAvailable                bool
	bumblebee                               bool
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
	return agentCapabilities(agentCapabilityOptions{
		enhancedBPF:                             remoteaccess.PlatformEnhancedRecordingAvailable(),
		desktopRDP:                              remoteAccessRDPCapabilityEnabled(cfg),
		hostNetworkVisibilityFingerprintEnabled: hasHealthyNetprobeSidecar(sidecars),
		sweepBannerGrabAvailable:                sweepBannerGrabAvailable,
		bumblebee:                               cfg != nil && cfg.Bumblebee != nil && cfg.Bumblebee.Enabled,
	})
}

func agentCapabilities(options agentCapabilityOptions) []string {
	capabilities := []string{
		"icmp",
		"mtr",
		sweepType,
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
		capabilityHostNetworkVisibility,
		capabilityHostNetworkVisibilityDPIUnavailable,
		capabilityHostNetworkVisibilityFlowUnavailable,
		capabilityHostNetworkVisibilitySnapshotUnavailable,
		capabilitySweepBannerGrab,
	}

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

	if options.bumblebee {
		capabilities = append(capabilities, "bumblebee")
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

var readSystemdUnitStatus = readSystemdUnitStatusDefault

// systemdAddonStatuses synthesizes `addon:<id>` entries so systemd-managed native
// add-ons land in the control-plane AddonStatus read model. These add-ons are not
// supervised by the go-plugin add-on manager, so they otherwise have no `addon:` status.
// The installed version comes from the activation `current` symlink (target
// `versions/<version>`). For add-ons that also expose a sidecar/IPC status such as
// netprobe, the richer sidecar state is folded in; standalone services such as
// workload-identity use systemd active state and MainPID.
func (p *PushLoop) systemdAddonStatuses(root string, sidecars []*proto.SidecarStatus) []*proto.SidecarStatus {
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

	if foldSidecarStatus(&st, id, sidecars) {
		return st
	}

	status := systemdAddonUnitStatus(units)
	st.State = status.state
	st.PID = status.pid
	st.LastError = status.lastError
	if status.state == agentaddon.StateRunning {
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

func systemdAddonUnitStatus(units []string) systemdUnitStatus {
	if len(units) == 0 {
		return systemdUnitStatus{state: agentaddon.StateStopped}
	}

	best := systemdUnitStatus{state: agentaddon.StateStopped}
	for _, unit := range units {
		status := readSystemdUnitStatus(unit)
		switch status.state {
		case agentaddon.StateRunning:
			return status
		case agentaddon.StateStarting, agentaddon.StateRestarting:
			best = status
		case agentaddon.StateUnhealthy:
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
		"--property=MainPID",
		"--value",
		unit,
	)
	out, err := cmd.Output()
	if err != nil {
		return systemdUnitStatus{
			state:     agentaddon.StateUnhealthy,
			lastError: fmt.Sprintf("systemctl show %s failed: %v", unit, err),
		}
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	activeState := ""
	if len(lines) > 0 {
		activeState = strings.TrimSpace(lines[0])
	}

	pid := 0
	if len(lines) > 1 {
		if parsed, parseErr := strconv.Atoi(strings.TrimSpace(lines[1])); parseErr == nil && parsed > 0 {
			pid = parsed
		}
	}

	switch activeState {
	case "active":
		return systemdUnitStatus{state: agentaddon.StateRunning, pid: pid}
	case "activating":
		return systemdUnitStatus{state: agentaddon.StateStarting, pid: pid}
	case "deactivating", "reloading":
		return systemdUnitStatus{state: agentaddon.StateRestarting, pid: pid}
	case "failed":
		return systemdUnitStatus{state: agentaddon.StateUnhealthy, pid: pid, lastError: "systemd unit failed"}
	default:
		return systemdUnitStatus{state: agentaddon.StateStopped, pid: pid}
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
	if cfg == nil || cfg.RemoteAccessRDPEnabled == nil || !*cfg.RemoteAccessRDPEnabled {
		return false
	}

	return remoteaccess.RDPAdapterReady(cfg.RemoteAccessRDPAdapterPath)
}
