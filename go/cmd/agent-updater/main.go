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
	"errors"
	"flag"
	"log"
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
	)
	flag.Parse()

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
