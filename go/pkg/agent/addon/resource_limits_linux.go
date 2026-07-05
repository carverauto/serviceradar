// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package addon

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/rs/zerolog"
)

var (
	errNoCgroupRootOrSlice = errors.New("resource limits declared but no addon cgroup root or systemd slice is configured")
	errEmptySystemdSlice   = errors.New("empty systemd slice")
	errInvalidSystemdSlice = errors.New("invalid systemd slice")
)

// applyResourceLimits places the add-on subprocess in a dedicated cgroup v2
// directory carrying the manifest-declared CPU/memory/task limits, so an edge
// compute add-on cannot impact the host or the base agent. cgroupRoot must be a
// cgroup v2 directory the agent may write to (a delegated sub-tree). On any hard
// failure it returns an error and the caller launches the add-on WITHOUT
// enforcement (best-effort, never blocks the add-on).
func applyResourceLimits(cmd *exec.Cmd, id string, res Resources, cgroupRoot string, log zerolog.Logger) (func(), string, error) {
	if res.IsZero() {
		return func() {}, "", nil
	}

	root, err := resolveAddonCgroupRoot(res, cgroupRoot)
	if err != nil {
		return nil, "", err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, "", fmt.Errorf("create addon cgroup root %s: %w", root, err)
	}

	dir := filepath.Join(root, "serviceradar-addon-"+id)
	if err := os.Mkdir(dir, 0o755); err != nil && !os.IsExist(err) {
		return nil, "", fmt.Errorf("create addon cgroup %s: %w", dir, err)
	}

	var writeErrs []error
	writeLimit := func(file, value string) {
		if err := os.WriteFile(filepath.Join(dir, file), []byte(value), 0o644); err != nil {
			writeErrs = append(writeErrs, fmt.Errorf("write %s: %w", file, err))
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
	if err := errors.Join(writeErrs...); err != nil {
		_ = os.Remove(dir)
		return nil, "", fmt.Errorf("apply addon cgroup limits in %s: %w", dir, err)
	}

	fd, err := os.Open(dir)
	if err != nil {
		return nil, "", fmt.Errorf("open addon cgroup %s: %w", dir, err)
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
	return cleanup, dir, nil
}

func resolveAddonCgroupRoot(res Resources, cgroupRoot string) (string, error) {
	if root := strings.TrimSpace(cgroupRoot); root != "" {
		return root, nil
	}

	// The manifest-declared systemd slice is the accounting boundary operators
	// see when no delegated process-supervision root is configured.
	if slice := strings.TrimSpace(res.Slice); slice != "" {
		return systemdSliceCgroupPath(slice)
	}

	return "", errNoCgroupRootOrSlice
}

func systemdSliceCgroupPath(slice string) (string, error) {
	slice = strings.TrimSpace(slice)
	if slice == "" {
		return "", errEmptySystemdSlice
	}
	if strings.Contains(slice, "/") || !strings.HasSuffix(slice, ".slice") {
		return "", fmt.Errorf("%w %q", errInvalidSystemdSlice, slice)
	}

	name := strings.TrimSuffix(slice, ".slice")
	parts := strings.Split(name, "-")
	path := "/sys/fs/cgroup"
	for i := range parts {
		path = filepath.Join(path, strings.Join(parts[:i+1], "-")+".slice")
	}

	return path, nil
}
