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

package ebpf

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

const envAgentEBPFIntegration = "SERVICERADAR_AGENT_EBPF_INTEGRATION"

func TestRuntimeLoadsSelftestCollectionIntegration(t *testing.T) {
	if os.Getenv(envAgentEBPFIntegration) != "1" {
		t.Skipf("set %s=1 on a compatible Linux host to load the eBPF self-test collection", envAgentEBPFIntegration)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	runtime := NewRuntime(Config{
		Enabled:            true,
		BPFFSPath:          envOrDefault("SERVICERADAR_AGENT_EBPF_BPFFS_PATH", DefaultBPFFSPath),
		BTFPath:            envOrDefault("SERVICERADAR_AGENT_EBPF_BTF_PATH", DefaultBTFPath),
		CgroupPath:         envOrDefault("SERVICERADAR_AGENT_EBPF_CGROUP_PATH", DefaultCgroupPath),
		AllowMissingBTF:    os.Getenv("SERVICERADAR_AGENT_EBPF_ALLOW_MISSING_BTF") == "1",
		AllowMissingCgroup: os.Getenv("SERVICERADAR_AGENT_EBPF_ALLOW_MISSING_CGROUP") == "1",
	})

	report := runtime.Check(ctx)
	if !report.Available {
		t.Fatalf("eBPF runtime unavailable: reasons=%v details=%v", report.Reasons, report.Details)
	}

	collection, err := runtime.LoadCollection(
		ctx,
		StaticCollectionSpec("remoteaccess-selftest", probes.LoadSelftestSpec),
	)
	if err != nil {
		t.Fatalf("load self-test collection: %v", err)
	}
	defer func() {
		if err := collection.Close(context.Background()); err != nil {
			t.Fatalf("close self-test collection: %v", err)
		}
	}()
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
