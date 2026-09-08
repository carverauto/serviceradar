// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAddonCgroupRootFromProc(t *testing.T) {
	tests := []struct {
		name     string
		contents string
		want     string
		wantMove bool
	}{
		{
			name:     "packaged systemd supervisor subgroup",
			contents: "0::/serviceradar.slice/serviceradar-agent.service/supervisor\n",
			want:     "/sys/fs/cgroup/serviceradar.slice/serviceradar-agent.service/addons",
		},
		{
			name:     "hybrid hierarchy uses unified entry",
			contents: "7:cpu,cpuacct:/legacy\n0::/system.slice/serviceradar-agent.service/supervisor\n",
			want:     "/sys/fs/cgroup/system.slice/serviceradar-agent.service/addons",
		},
		{
			name:     "old unit without supervisor subgroup moves itself",
			contents: "0::/serviceradar.slice/serviceradar-agent.service\n",
			want:     "/sys/fs/cgroup/serviceradar.slice/serviceradar-agent.service/addons",
			wantMove: true,
		},
		{
			name:     "unrelated service supervisor is rejected",
			contents: "0::/system.slice/other.service/supervisor\n",
		},
		{
			name:     "cgroup v1 has no runtime default",
			contents: "7:cpu,cpuacct:/serviceradar\n6:memory:/serviceradar\n",
		},
		{
			name:     "relative unified path is rejected",
			contents: "0::serviceradar.slice/serviceradar-agent.service/supervisor\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, gotMove := addonCgroupRootFromProc([]byte(tt.contents), cgroupV2Mount)
			if got != tt.want {
				t.Fatalf("addonCgroupRootFromProc() = %q, want %q", got, tt.want)
			}
			if gotMove != tt.wantMove {
				t.Fatalf("addonCgroupRootFromProc() move = %t, want %t", gotMove, tt.wantMove)
			}
		})
	}
}

func TestMoveAgentToSupervisorCgroup(t *testing.T) {
	serviceRoot := t.TempDir()
	addonRoot := filepath.Join(serviceRoot, "addons")

	if err := moveAgentToSupervisorCgroup(addonRoot, 4242); err != nil {
		t.Fatalf("move agent to supervisor cgroup: %v", err)
	}

	contents, err := os.ReadFile(filepath.Join(serviceRoot, "supervisor", "cgroup.procs"))
	if err != nil {
		t.Fatalf("read supervisor cgroup.procs: %v", err)
	}
	if got, want := string(contents), "4242"; got != want {
		t.Fatalf("supervisor cgroup.procs = %q, want %q", got, want)
	}
}
