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
	"encoding/json"
	"path/filepath"
	"runtime"
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
	if netprobeStatus := p.netprobeAddonStatus(resolveAddonArtifactRoot(""), sidecars); netprobeStatus != nil {
		sidecars = append(sidecars, netprobeStatus)
	}

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

// netprobeAddonStatus synthesizes an `addon:netprobe` entry so the systemd-managed
// netprobe add-on lands in the control-plane AddonStatus read model (Edge Ops drift),
// which only ingests `addon:<id>` sidecar entries. netprobe is supervised as a
// systemd-service (not the go-plugin addon manager) and otherwise reports under the bare
// "netprobe" sidecar name, so it would never reach the read model. Returns nil when
// netprobe is not installed as a systemd add-on on this host. The installed version comes
// from the activation `current` symlink (target `versions/<version>`); arch is the host
// arch (the agent runs the arch-matching artifact); live state/health is folded in from
// the running netprobe sidecar entry when present. Reuses agentaddon.ToProtoStatuses for
// the `addon:` prefix + version/arch mapping. Explicit capture-active reporting needs a
// netprobe IPC signal (follow-up); a running-but-incapable netprobe still surfaces via its
// state + last_error.
func (p *PushLoop) netprobeAddonStatus(root string, sidecars []*proto.SidecarStatus) *proto.SidecarStatus {
	id := agentnetprobe.DefaultSidecarName
	if len(p.systemdAddonUnits(id)) == 0 {
		return nil
	}

	st := agentaddon.Status{
		ID:    id,
		State: agentaddon.StateStopped,
		Arch:  runtime.GOARCH,
	}
	if target, ok := readAddonCurrentTarget(filepath.Join(root, id)); ok {
		st.Version = filepath.Base(target)
	}

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

		break
	}

	out := agentaddon.ToProtoStatuses([]agentaddon.Status{st})
	if len(out) == 0 {
		return nil
	}

	return out[0]
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
