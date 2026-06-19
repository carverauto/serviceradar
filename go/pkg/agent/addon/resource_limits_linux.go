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
	"strings"
	"syscall"

	"github.com/rs/zerolog"
)

// applyResourceLimits places the add-on subprocess in a dedicated cgroup v2
// directory carrying the manifest-declared CPU/memory/task limits, so an edge
// compute add-on cannot impact the host or the base agent. cgroupRoot must be a
// cgroup v2 directory the agent may write to (a delegated sub-tree). On any hard
// failure it returns an error and the caller launches the add-on WITHOUT
// enforcement (best-effort, never blocks the add-on).
func applyResourceLimits(
	cmd *exec.Cmd,
	id string,
	res Resources,
	cgroupRoot string,
	log zerolog.Logger,
) (func(), resourceLimitStatus, error) {
	if res.IsZero() || cgroupRoot == "" {
		if res.IsZero() {
			return noResourceLimitCleanup, resourceLimitStatus{}, nil
		}
		status := resourceLimitWarning("addon resource limits declared but addon_cgroup_root is not configured")
		log.Warn().Str("addon", id).Msg(status.Warning)
		return noResourceLimitCleanup, status, nil
	}

	parent := addonCgroupParent(cgroupRoot, res)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		status := resourceLimitWarning("create addon cgroup parent %s: %v", parent, err)
		return noResourceLimitCleanup, status, fmt.Errorf("create addon cgroup parent %s: %w", parent, err)
	}

	dir := filepath.Join(parent, "serviceradar-addon-"+id)
	if err := os.Mkdir(dir, 0o755); err != nil && !os.IsExist(err) {
		status := resourceLimitWarning("create addon cgroup %s: %v", dir, err)
		return noResourceLimitCleanup, status, fmt.Errorf("create addon cgroup %s: %w", dir, err)
	}

	var writeFailures []string
	writeLimit := func(file, value string) {
		if err := os.WriteFile(filepath.Join(dir, file), []byte(value), 0o644); err != nil {
			writeFailures = append(writeFailures, fmt.Sprintf("%s: %v", file, err))
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
		status := resourceLimitWarning("open addon cgroup %s: %v", dir, err)
		status.CgroupPath = dir
		return func() { _ = os.Remove(dir) }, status, fmt.Errorf("open addon cgroup %s: %w", dir, err)
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.UseCgroupFD = true
	cmd.SysProcAttr.CgroupFD = int(fd.Fd())

	status := resourceLimitStatus{
		Requested:  true,
		Enforced:   len(writeFailures) == 0,
		CgroupPath: dir,
	}
	if len(writeFailures) > 0 {
		status.Warning = "addon cgroup limits partially applied: " + strings.Join(writeFailures, "; ")
	}

	cleanup := func() {
		_ = fd.Close()
		// Best-effort: rmdir only succeeds once the subprocess has exited and the
		// cgroup is empty.
		_ = os.Remove(dir)
	}

	if status.Warning != "" {
		return cleanup, status, fmt.Errorf("%s", status.Warning)
	}

	return cleanup, status, nil
}
