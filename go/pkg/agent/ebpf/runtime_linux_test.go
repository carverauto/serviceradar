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
	"path/filepath"
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
