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

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/agent"
	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/agent/updaterflags"
)

var errVersionRequired = errors.New("version is required")

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	opts := updaterflags.Register(flag.CommandLine)
	flag.Parse()

	ctx := context.Background()

	switch {
	case opts.AddonSystemdInstall != "":
		resources, err := parseAddonResources(opts.AddonSystemdResources)
		if err != nil {
			return err
		}
		privileged, err := agent.PrivilegedRootForSetuidInstall(opts.PrivilegedRoot, opts.RuntimeRoot)
		if err != nil {
			return err
		}

		return agent.InstallAddonSystemdUnits(ctx, agent.AddonSystemdInstallRequest{
			PrivilegedRoot:    privileged,
			AddonID:           opts.AddonID,
			Version:           opts.AddonVersion,
			BinaryName:        opts.AddonBinary,
			ArtifactPath:      opts.AddonArtifact,
			ArtifactSHA256:    opts.AddonSHA256,
			Signature:         opts.AddonSignature,
			Units:             splitCommaList(opts.AddonSystemdInstall),
			Enable:            opts.AddonSystemdEnable,
			Resources:         resources,
			Capabilities:      splitCommaList(opts.AddonCapabilities),
			RunTimerNow:       opts.AddonSystemdRunTimerNow,
			StateSnapshotPath: opts.AddonStateSnapshot,
		})
	case opts.AddonSystemdUninstall != "":
		return agent.UninstallAddonSystemdUnits(ctx, splitCommaList(opts.AddonSystemdUninstall))
	case opts.Version != "":
		return agent.ActivateStagedRelease(agent.ReleaseActivationConfig{
			RuntimeRoot:      opts.RuntimeRoot,
			Version:          opts.Version,
			CommandID:        opts.CommandID,
			CommandType:      opts.CommandType,
			RollbackDeadline: opts.RollbackDeadline,
		})
	default:
		return errVersionRequired
	}
}

// splitCommaList splits a comma-separated flag value into trimmed, non-empty items.
func splitCommaList(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}

	return out
}

// parseAddonResources decodes the JSON resource limits passed by the agent for a
// systemd-supervised add-on. An empty value yields zero limits (no drop-in).
func parseAddonResources(encoded string) (agentaddon.Resources, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return agentaddon.Resources{}, nil
	}

	var resources agentaddon.Resources
	if err := json.Unmarshal([]byte(encoded), &resources); err != nil {
		return agentaddon.Resources{}, fmt.Errorf("parse --addon-systemd-resources: %w", err)
	}

	return resources, nil
}
