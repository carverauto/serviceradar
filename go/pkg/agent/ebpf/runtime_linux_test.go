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
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeCheckReportsMissingLinuxSurfaces(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	report := NewRuntime(Config{
		Enabled:           true,
		BPFFSPath:         filepath.Join(root, "missing-bpffs"),
		BTFPath:           filepath.Join(root, "missing-btf"),
		CgroupPath:        filepath.Join(root, "missing-cgroup"),
		SkipFeatureProbes: true,
	}).Check(context.Background())

	if report.Available {
		t.Fatalf("report should be unavailable: %#v", report)
	}
	for _, reason := range []DisabledReason{ReasonMissingBPFFS, ReasonMissingBTF, ReasonMissingCgroup} {
		if !report.HasReason(reason) {
			t.Fatalf("report missing reason %q: %#v", reason, report)
		}
	}
}

func TestRuntimeCheckAcceptsConfiguredLinuxSurfaces(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	bpffs := filepath.Join(root, "bpffs")
	cgroup := filepath.Join(root, "cgroup")
	btf := filepath.Join(root, "vmlinux")
	if err := os.Mkdir(bpffs, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(cgroup, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(btf, []byte("btf"), 0o644); err != nil {
		t.Fatal(err)
	}

	report := NewRuntime(Config{
		Enabled:           true,
		BPFFSPath:         bpffs,
		BTFPath:           btf,
		CgroupPath:        cgroup,
		SkipFeatureProbes: true,
	}).Check(context.Background())

	if !report.Available {
		t.Fatalf("report should be available: %#v", report)
	}
}

func TestKernelAtLeastParsesLinuxReleases(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		release string
		want    bool
	}{
		{name: "minimum", release: "5.8.0", want: true},
		{name: "newer patch", release: "5.15.0-105-generic", want: true},
		{name: "newer major", release: "6.8.11", want: true},
		{name: "older minor", release: "5.4.0-200-generic", want: false},
		{name: "invalid", release: "not-a-kernel", want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			if got := kernelAtLeast(tc.release, minKernelMajor, minKernelMinor); got != tc.want {
				t.Fatalf("kernelAtLeast(%q) = %v, want %v", tc.release, got, tc.want)
			}
		})
	}
}

func TestMissingEffectiveCapsFromStatusReportsNamedCaps(t *testing.T) {
	t.Parallel()

	missing, err := missingEffectiveCapsFromStatus(
		[]byte("Name:\ttest\nCapEff:\t0000000000000000\n"),
		map[string]int{
			"CAP_BPF":     linuxCapBPF,
			"CAP_PERFMON": linuxCapPerfmon,
		},
	)
	if err != nil {
		t.Fatalf("missingEffectiveCapsFromStatus error = %v", err)
	}
	if got, want := strings.Join(missing, ","), "CAP_BPF,CAP_PERFMON"; got != want {
		t.Fatalf("missing caps = %q, want %q", got, want)
	}
}

func TestMissingEffectiveCapsFromStatusAcceptsRequiredCaps(t *testing.T) {
	t.Parallel()

	capEff := (uint64(1) << linuxCapBPF) | (uint64(1) << linuxCapPerfmon)
	status := []byte(fmt.Sprintf("CapEff:\t%016x\n", capEff))
	missing, err := missingEffectiveCapsFromStatus(
		status,
		map[string]int{
			"CAP_BPF":     linuxCapBPF,
			"CAP_PERFMON": linuxCapPerfmon,
		},
	)
	if err != nil {
		t.Fatalf("missingEffectiveCapsFromStatus error = %v", err)
	}
	if len(missing) != 0 {
		t.Fatalf("missing caps = %#v, want none", missing)
	}
}
