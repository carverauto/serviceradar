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

// Command serviceradar-sample-addon is a reference native agent add-on that
// exercises the issue-3425 add-on contract end to end. It implements the
// addon.Addon interface and is served via the first-party SDK so the agent's
// add-on manager can launch, configure, health-check, and supervise it as a
// go-plugin gRPC subprocess.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/addon/sdk"
)

const (
	addonID      = "sample"
	addonVersion = "0.1.0"
)

// sampleAddon is a minimal, no-op add-on that reports healthy and echoes a hash
// of whatever configuration it is given.
type sampleAddon struct{}

func (a *sampleAddon) Info(context.Context) (addon.Info, error) {
	return addon.Info{
		ID:           addonID,
		Version:      addonVersion,
		Capabilities: []string{"sample"},
	}, nil
}

func (a *sampleAddon) Configure(_ context.Context, configJSON []byte) (addon.ConfigureResult, error) {
	sum := sha256.Sum256(configJSON)
	return addon.ConfigureResult{
		ConfigHash: hex.EncodeToString(sum[:]),
		Accepted:   true,
	}, nil
}

func (a *sampleAddon) Health(context.Context) (addon.Health, error) {
	return addon.Health{
		Status:  addon.HealthHealthy,
		Version: addonVersion,
	}, nil
}

func (a *sampleAddon) RunCommand(_ context.Context, request addon.CommandRequest) (addon.CommandResult, error) {
	payload, err := json.Marshal(map[string]any{
		"schema":     "serviceradar.sample_addon_command_result.v1",
		"status":     "succeeded",
		"action_id":  request.ActionID,
		"command_id": request.CommandID,
	})
	if err != nil {
		return addon.CommandResult{}, err
	}

	return addon.CommandResult{
		Success:     true,
		Message:     "sample command completed",
		PayloadJSON: payload,
	}, nil
}

func main() {
	sdk.Serve(&sampleAddon{})
}
