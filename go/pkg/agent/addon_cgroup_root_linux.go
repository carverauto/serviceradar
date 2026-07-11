// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	selfCgroupPath = "/proc/self/cgroup"
	cgroupV2Mount  = "/sys/fs/cgroup"
)

func defaultAddonCgroupRoot() (string, error) {
	contents, err := os.ReadFile(selfCgroupPath)
	if err != nil {
		return "", fmt.Errorf("read process cgroup: %w", err)
	}

	root, needsSupervisorMove := addonCgroupRootFromProc(contents, cgroupV2Mount)
	if root == "" || !needsSupervisorMove {
		return root, nil
	}

	if err := moveAgentToSupervisorCgroup(root, os.Getpid()); err != nil {
		return "", err
	}

	return root, nil
}

func moveAgentToSupervisorCgroup(addonRoot string, pid int) error {
	supervisor := filepath.Join(filepath.Dir(addonRoot), "supervisor")
	if err := os.Mkdir(supervisor, 0o755); err != nil && !os.IsExist(err) {
		return fmt.Errorf("create agent supervisor cgroup %s: %w", supervisor, err)
	}

	if err := os.WriteFile(
		filepath.Join(supervisor, "cgroup.procs"),
		[]byte(strconv.Itoa(pid)),
		0o644,
	); err != nil {
		return fmt.Errorf("move agent into supervisor cgroup %s: %w", supervisor, err)
	}

	return nil
}

func addonCgroupRootFromProc(contents []byte, mount string) (string, bool) {
	for line := range strings.SplitSeq(string(contents), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 3)
		if len(parts) != 3 || parts[0] != "0" || parts[1] != "" {
			continue
		}

		processPath := filepath.Clean(parts[2])
		if !filepath.IsAbs(processPath) {
			return "", false
		}

		delegatedRoot := processPath
		needsSupervisorMove := true
		if filepath.Base(processPath) == "supervisor" {
			delegatedRoot = filepath.Dir(processPath)
			needsSupervisorMove = false
		}
		if filepath.Base(delegatedRoot) != "serviceradar-agent.service" {
			return "", false
		}
		if delegatedRoot == "/" || delegatedRoot == "." {
			return "", false
		}

		return filepath.Join(filepath.Clean(mount), strings.TrimPrefix(delegatedRoot, "/"), "addons"),
			needsSupervisorMove
	}

	return "", false
}
