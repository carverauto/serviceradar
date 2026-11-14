/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/agent/updaterflags"
)

const maxAgentUpdaterOutputBytes = 65_536

// ErrAgentUpdaterPermanentRefusal marks an agent-updater invocation that exited
// with updaterflags.ExitPermanentRefusal (78), allowing callers to classify a
// deterministic refusal across the subprocess boundary without matching stderr text.
var ErrAgentUpdaterPermanentRefusal = errors.New("agent-updater permanent install refusal")

// agentUpdaterArgs is an agent-updater command line together with the names of
// the flags it passes, so the flags probed on the installed updater are exactly
// the flags the command uses.
type agentUpdaterArgs struct {
	flags []string
	args  []string
}

func (a *agentUpdaterArgs) set(name, value string) {
	a.flags = append(a.flags, name)
	a.args = append(a.args, "--"+name, value)
}

func (a *agentUpdaterArgs) enable(name string) {
	a.flags = append(a.flags, name)
	a.args = append(a.args, "--"+name)
}

func runAgentUpdaterCommand(ctx context.Context, updaterPath string, args ...string) error {
	cmd := exec.CommandContext(ctx, updaterPath, args...)

	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}

	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) && exitErr.ExitCode() == updaterflags.ExitPermanentRefusal {
		err = fmt.Errorf("%w: %w", ErrAgentUpdaterPermanentRefusal, err)
	}

	output := strings.TrimSpace(string(out))
	if output == "" {
		return err
	}

	return fmt.Errorf("%w: %s", err, truncateAgentUpdaterOutput(output))
}

func truncateAgentUpdaterOutput(output string) string {
	if len(output) <= maxAgentUpdaterOutputBytes {
		return output
	}

	return fmt.Sprintf("updater output overflowed (%d bytes > %d limit)", len(output), maxAgentUpdaterOutputBytes)
}
