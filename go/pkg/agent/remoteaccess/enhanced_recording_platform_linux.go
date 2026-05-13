//go:build linux

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

package remoteaccess

import (
	"context"
	"os"
	"strings"

	agentebpf "github.com/carverauto/serviceradar/go/pkg/agent/ebpf"
	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

const (
	envAgentEBPFEnabled    = "SERVICERADAR_AGENT_EBPF_ENABLED"
	envAgentEBPFBPFFSPath  = "SERVICERADAR_AGENT_EBPF_BPFFS_PATH"
	envAgentEBPFBTFPath    = "SERVICERADAR_AGENT_EBPF_BTF_PATH"
	envAgentEBPFCgroupPath = "SERVICERADAR_AGENT_EBPF_CGROUP_PATH"
)

// PlatformEnhancedRecordingAvailable reports whether this host has a
// ServiceRadar-owned BPF collector that can satisfy required BPF policies.
// The procfs collector returned by NewPlatformEnhancedRecorder is an
// optional/fallback collector and must not advertise the BPF capability.
func PlatformEnhancedRecordingAvailable() bool {
	return linuxBPFRemoteAccessCapabilityReport(context.Background()).Available
}

func linuxBPFRemoteAccessCapabilityReport(ctx context.Context) agentebpf.CapabilityReport {
	runtime := linuxBPFRemoteAccessRuntimeFromEnv()
	report := runtime.Check(ctx)
	if !report.Available {
		return report
	}

	collection, err := runtime.LoadCollection(
		ctx,
		agentebpf.StaticCollectionSpec("remoteaccess-selftest", probes.LoadSelftestSpec),
	)
	if err != nil {
		report.AddReason(agentebpf.ReasonSelfTestFailed)
		return report
	}
	if err := collection.Close(ctx); err != nil {
		report.AddReason(agentebpf.ReasonSelfTestFailed)
		return report
	}

	return report
}

func linuxBPFRemoteAccessRuntimeFromEnv() *agentebpf.Runtime {
	return agentebpf.NewRuntime(agentebpf.Config{
		Enabled:    envBool(envAgentEBPFEnabled),
		BPFFSPath:  firstNonEmpty(os.Getenv(envAgentEBPFBPFFSPath), agentebpf.DefaultBPFFSPath),
		BTFPath:    firstNonEmpty(os.Getenv(envAgentEBPFBTFPath), agentebpf.DefaultBTFPath),
		CgroupPath: firstNonEmpty(os.Getenv(envAgentEBPFCgroupPath), agentebpf.DefaultCgroupPath),
	})
}

func envBool(name string) bool {
	switch strings.TrimSpace(strings.ToLower(os.Getenv(name))) {
	case "1", enhancedMetadataTrue, "yes", "on":
		return true
	default:
		return false
	}
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// NewPlatformEnhancedRecorder returns the Linux host-event fallback collector.
// It reads public procfs surfaces and refuses required BPF policies unless the
// policy explicitly allows fallback.
func NewPlatformEnhancedRecorder() EnhancedRecorder {
	return NewSourceEnhancedRecorder(NewLinuxProcEnhancedEventSource())
}
