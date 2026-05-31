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
	"errors"
	"flag"
	"log"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent"
)

var errVersionRequired = errors.New("version is required")

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	var (
		runtimeRoot      = flag.String("runtime-root", "", "ServiceRadar runtime root")
		version          = flag.String("version", "", "Target staged release version")
		commandID        = flag.String("command-id", "", "Command ID for activation result reporting")
		commandType      = flag.String("command-type", "agent.update_release", "Command type for activation result reporting")
		rollbackDeadline = flag.Duration("rollback-deadline", 3*time.Minute, "Rollback deadline after activation")

		// Add-on file-capability application mode (delivery-models task 2.2). When
		// --addon-id is set the updater applies the requested Linux capabilities to the
		// staged add-on binary via setcap instead of activating an agent release.
		addonID   = flag.String("addon-id", "", "Add-on id; selects capability-application mode")
		addonBin  = flag.String("addon-binary", "", "Staged add-on binary filename to apply capabilities to")
		addonCaps = flag.String("addon-capabilities", "", "Comma-separated Linux file capabilities to apply (e.g. cap_net_raw,cap_bpf)")
	)
	flag.Parse()

	if *addonID != "" {
		return agent.ApplyAddonCapabilities(context.Background(), agent.AddonCapabilityRequest{
			RuntimeRoot:  *runtimeRoot,
			AddonID:      *addonID,
			BinaryName:   *addonBin,
			Capabilities: splitCommaList(*addonCaps),
		})
	}

	if *version == "" {
		return errVersionRequired
	}

	return agent.ActivateStagedRelease(agent.ReleaseActivationConfig{
		RuntimeRoot:      *runtimeRoot,
		Version:          *version,
		CommandID:        *commandID,
		CommandType:      *commandType,
		RollbackDeadline: *rollbackDeadline,
	})
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
