// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package addon

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"

	"github.com/rs/zerolog"
)

// applyResourceLimits places the add-on subprocess in a dedicated cgroup v2
// directory carrying the manifest-declared CPU/memory/task limits, so an edge
// compute add-on cannot impact the host or the base agent. cgroupRoot must be a
// cgroup v2 directory the agent may write to (a delegated sub-tree). On any hard
// failure it returns an error and the caller launches the add-on WITHOUT
// enforcement (best-effort, never blocks the add-on).
func applyResourceLimits(cmd *exec.Cmd, id string, res Resources, cgroupRoot string, log zerolog.Logger) (func(), error) {
	if res.IsZero() || cgroupRoot == "" {
		return func() {}, nil
	}

	dir := filepath.Join(cgroupRoot, "serviceradar-addon-"+id)
	if err := os.Mkdir(dir, 0o755); err != nil && !os.IsExist(err) {
		return nil, fmt.Errorf("create addon cgroup %s: %w", dir, err)
	}

	writeLimit := func(file, value string) {
		if err := os.WriteFile(filepath.Join(dir, file), []byte(value), 0o644); err != nil {
			log.Warn().Err(err).Str("addon", id).Str("cgroup_file", file).
				Msg("addon cgroup limit not applied")
		}
	}
	if res.MemoryMaxBytes > 0 {
		writeLimit("memory.max", strconv.FormatInt(res.MemoryMaxBytes, 10))
	}
	if res.MemoryHighBytes > 0 {
		writeLimit("memory.high", strconv.FormatInt(res.MemoryHighBytes, 10))
	}
	if res.CPUMaxPercent > 0 {
		// cgroup v2 cpu.max is "<quota_us> <period_us>"; quota = percent of one core.
		const periodUs = 100000
		quota := int64(res.CPUMaxPercent / 100.0 * float64(periodUs))
		if quota < 1 {
			quota = 1
		}
		writeLimit("cpu.max", fmt.Sprintf("%d %d", quota, periodUs))
	}
	if res.TasksMax > 0 {
		writeLimit("pids.max", strconv.Itoa(res.TasksMax))
	}

	fd, err := os.Open(dir)
	if err != nil {
		return nil, fmt.Errorf("open addon cgroup %s: %w", dir, err)
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.UseCgroupFD = true
	cmd.SysProcAttr.CgroupFD = int(fd.Fd())

	cleanup := func() {
		_ = fd.Close()
		// Best-effort: rmdir only succeeds once the subprocess has exited and the
		// cgroup is empty.
		_ = os.Remove(dir)
	}
	return cleanup, nil
}
