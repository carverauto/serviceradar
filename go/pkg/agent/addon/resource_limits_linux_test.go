// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package addon

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/rs/zerolog"
)

// TestApplyResourceLimitsPlacesChildInCgroup validates the cgroup v2 enforcement
// on a real Linux host (it is skipped unless a delegated cgroup is provided).
// Set ADDON_TEST_CGROUP_PARENT to a cgroup v2 directory whose subtree_control
// delegates cpu/memory/pids; the test creates a child cgroup under it via
// applyResourceLimits, asserts the limit files, and confirms the child process
// is placed inside it.
func TestApplyResourceLimitsPlacesChildInCgroup(t *testing.T) {
	parent := os.Getenv("ADDON_TEST_CGROUP_PARENT")
	if parent == "" {
		t.Skip("set ADDON_TEST_CGROUP_PARENT to a cgroup v2 dir with cpu/memory/pids delegated")
	}

	res := Resources{
		CPUMaxPercent:   50,
		MemoryMaxBytes:  64 << 20,
		MemoryHighBytes: 48 << 20,
		TasksMax:        16,
	}

	cmd := exec.CommandContext(context.Background(), "/bin/sleep", "30")
	cleanup, _, err := applyResourceLimits(cmd, "itest", res, parent, zerolog.Nop())
	if err != nil {
		t.Fatalf("applyResourceLimits: %v", err)
	}
	t.Cleanup(cleanup)

	dir := filepath.Join(parent, "serviceradar-addon-itest")
	assertCgroupFile(t, filepath.Join(dir, "memory.max"), strconv.Itoa(64<<20))
	assertCgroupFile(t, filepath.Join(dir, "memory.high"), strconv.Itoa(48<<20))
	assertCgroupFile(t, filepath.Join(dir, "pids.max"), "16")
	// 50% of one core: quota 50000us / period 100000us.
	assertCgroupFile(t, filepath.Join(dir, "cpu.max"), "50000 100000")

	if err := cmd.Start(); err != nil {
		t.Fatalf("start child: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})

	procs, err := os.ReadFile(filepath.Join(dir, "cgroup.procs"))
	if err != nil {
		t.Fatalf("read cgroup.procs: %v", err)
	}
	want := strconv.Itoa(cmd.Process.Pid)
	found := false
	for _, line := range strings.Split(string(procs), "\n") {
		if strings.TrimSpace(line) == want {
			found = true
		}
	}
	if !found {
		t.Fatalf("child pid %s not placed in cgroup; cgroup.procs=%q", want, string(procs))
	}
}

func TestSystemdSliceCgroupPath(t *testing.T) {
	tests := []struct {
		name  string
		slice string
		want  string
	}{
		{
			name:  "top level slice",
			slice: "serviceradar-addons.slice",
			want:  "/sys/fs/cgroup/serviceradar.slice/serviceradar-addons.slice",
		},
		{
			name:  "nested slice",
			slice: "serviceradar-addons-anomaly.slice",
			want:  "/sys/fs/cgroup/serviceradar.slice/serviceradar-addons.slice/serviceradar-addons-anomaly.slice",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := systemdSliceCgroupPath(tt.slice)
			if err != nil {
				t.Fatalf("systemdSliceCgroupPath: %v", err)
			}
			if got != tt.want {
				t.Fatalf("systemdSliceCgroupPath(%q) = %q, want %q", tt.slice, got, tt.want)
			}
		})
	}
}

func TestResolveAddonCgroupRootRequiresRootOrSlice(t *testing.T) {
	_, err := resolveAddonCgroupRoot(Resources{MemoryMaxBytes: 64 << 20}, "")
	if err == nil {
		t.Fatalf("expected error for declared limits without root or slice")
	}

	got, err := resolveAddonCgroupRoot(Resources{MemoryMaxBytes: 64 << 20}, "/tmp/addons")
	if err != nil {
		t.Fatalf("resolve explicit root: %v", err)
	}
	if got != "/tmp/addons" {
		t.Fatalf("explicit root = %q, want /tmp/addons", got)
	}

	got, err = resolveAddonCgroupRoot(Resources{MemoryMaxBytes: 64 << 20, Slice: "serviceradar-addons.slice"}, "")
	if err != nil {
		t.Fatalf("resolve slice root: %v", err)
	}
	if got != "/sys/fs/cgroup/serviceradar.slice/serviceradar-addons.slice" {
		t.Fatalf("slice root = %q, want serviceradar-addons.slice path", got)
	}

	got, err = resolveAddonCgroupRoot(Resources{MemoryMaxBytes: 64 << 20, Slice: "serviceradar-addons.slice"}, "/tmp/addons")
	if err != nil {
		t.Fatalf("resolve explicit root over slice: %v", err)
	}
	if got != "/tmp/addons" {
		t.Fatalf("explicit root with slice = %q, want /tmp/addons", got)
	}
}

func TestRequiredCgroupControllers(t *testing.T) {
	tests := []struct {
		name string
		res  Resources
		want []string
	}{
		{name: "none", res: Resources{}},
		{name: "cpu", res: Resources{CPUMaxPercent: 50}, want: []string{"cpu"}},
		{name: "memory high", res: Resources{MemoryHighBytes: 64 << 20}, want: []string{"memory"}},
		{name: "memory max", res: Resources{MemoryMaxBytes: 64 << 20}, want: []string{"memory"}},
		{name: "tasks", res: Resources{TasksMax: 16}, want: []string{"pids"}},
		{
			name: "all",
			res: Resources{
				CPUMaxPercent:   50,
				MemoryMaxBytes:  64 << 20,
				MemoryHighBytes: 48 << 20,
				TasksMax:        16,
			},
			want: []string{"cpu", "memory", "pids"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := requiredCgroupControllers(tt.res); !slices.Equal(got, tt.want) {
				t.Fatalf("requiredCgroupControllers() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestEnableCgroupControllers(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cgroup.controllers"), []byte("cpu io memory pids"), 0o644); err != nil {
		t.Fatalf("write available controllers: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cgroup.subtree_control"), nil, 0o644); err != nil {
		t.Fatalf("write subtree controllers: %v", err)
	}

	required := []string{"cpu", "memory", "pids"}
	if err := enableCgroupControllers(dir, required); err != nil {
		t.Fatalf("enable controllers: %v", err)
	}

	contents, err := os.ReadFile(filepath.Join(dir, "cgroup.subtree_control"))
	if err != nil {
		t.Fatalf("read subtree controllers: %v", err)
	}
	if got, want := string(contents), "+cpu +memory +pids"; got != want {
		t.Fatalf("cgroup.subtree_control = %q, want %q", got, want)
	}

	if err := enableCgroupControllers(dir, required); err != nil {
		t.Fatalf("enable already configured controllers: %v", err)
	}

	if err := enableCgroupControllers(dir, []string{"cpuset"}); !errors.Is(err, errCgroupController) {
		t.Fatalf("missing controller error = %v, want %v", err, errCgroupController)
	}
}

func assertCgroupFile(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if g := strings.TrimSpace(string(got)); g != want {
		t.Fatalf("%s = %q, want %q", path, g, want)
	}
}
