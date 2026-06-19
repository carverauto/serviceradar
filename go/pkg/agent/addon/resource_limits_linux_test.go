// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package addon

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
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
		Slice:           "serviceradar-addons.slice",
	}

	cmd := exec.CommandContext(context.Background(), "/bin/sleep", "30")
	cleanup, status, err := applyResourceLimits(cmd, "itest", res, parent, zerolog.Nop())
	if err != nil {
		t.Fatalf("applyResourceLimits: %v", err)
	}
	t.Cleanup(cleanup)

	dir := filepath.Join(parent, "serviceradar-addons.slice", "serviceradar-addon-itest")
	if !status.Requested || !status.Enforced || status.CgroupPath != dir {
		t.Fatalf("resource limit status = %+v, want enforced at %s", status, dir)
	}
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
