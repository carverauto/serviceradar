// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//go:build !linux

package addon

import (
	"errors"
	"fmt"
	"os/exec"
	"runtime"

	"github.com/rs/zerolog"
)

var errCgroupEnforcementUnavailable = errors.New("cgroup enforcement is unavailable")

// applyResourceLimits reports declared limits as unenforced on non-Linux
// platforms: cgroup v2 enforcement is Linux-only. Edge add-ons run on Linux
// agents; this stub keeps the agent buildable on darwin/windows for development.
func applyResourceLimits(_ *exec.Cmd, id string, res Resources, _ string, log zerolog.Logger) (func(), string, error) {
	if !res.IsZero() {
		log.Debug().Str("addon", id).
			Msg("add-on resource limits declared but cgroup enforcement is unavailable on this platform")

		return nil, "", fmt.Errorf("resource limits declared but %w on %s", errCgroupEnforcementUnavailable, runtime.GOOS)
	}
	return func() {}, "", nil
}
