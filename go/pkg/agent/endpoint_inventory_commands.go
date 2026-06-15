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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/proto"
)

const maxEndpointInventoryCommandResultBytes = 64 * 1024

var (
	errEndpointInventoryCommandPayloadTooLarge = errors.New("endpoint inventory command result exceeds payload budget")
	errEndpointInventoryForceFreshDisabled     = errors.New("endpoint inventory force-fresh is disabled by policy")
	errEndpointInventoryForceFreshUnauthorized = errors.New("endpoint inventory force-fresh command is not authorized")
	errEndpointInventoryFreshScanBusy          = errors.New("endpoint inventory force-fresh scan already running")
	errEndpointInventorySourceDisabled         = errors.New("endpoint inventory source disabled")
)

func (p *PushLoop) handleEndpointInventoryCacheQuery(cmd *proto.CommandRequest, sender *controlStreamSender) {
	query := endpointinventory.EndpointInventoryQuery{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &query); err != nil {
			sendEndpointInventoryCommandResult(sender, cmd, false, "invalid endpoint inventory query payload", map[string]any{
				"error": "invalid_payload",
			})
			return
		}
	}

	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		sendEndpointInventoryCommandResult(sender, cmd, false, err.Error(), map[string]any{
			"error": "config_unavailable",
		})
		return
	}

	result, err := endpointinventory.EvaluateCacheQuery(cfg, query, time.Now().UTC())
	if err != nil {
		sendEndpointInventoryCommandResult(sender, cmd, false, err.Error(), map[string]any{
			"error": err.Error(),
		})
		return
	}

	sendEndpointInventoryCommandResult(sender, cmd, true, "endpoint inventory cache query completed", result)
}

func (p *PushLoop) handleEndpointInventoryForceFreshScan(
	ctx context.Context,
	cmd *proto.CommandRequest,
	sender *controlStreamSender,
) {
	payload := endpointinventory.EndpointInventoryForceFreshCommand{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			sendEndpointInventoryCommandResult(sender, cmd, false, "invalid endpoint inventory force-fresh payload", map[string]any{
				"error": "invalid_payload",
			})
			return
		}
	}

	if !payload.Authorized {
		sendEndpointInventoryCommandResult(sender, cmd, false, errEndpointInventoryForceFreshUnauthorized.Error(), map[string]any{
			"error": "force_fresh_unauthorized",
		})
		return
	}
	if !p.tryAcquireEndpointInventoryFreshScanSlot() {
		sendEndpointInventoryCommandResult(sender, cmd, false, errEndpointInventoryFreshScanBusy.Error(), map[string]any{
			"error": "force_fresh_busy",
		})
		return
	}
	defer p.releaseEndpointInventoryFreshScanSlot()

	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		sendEndpointInventoryCommandResult(sender, cmd, false, err.Error(), map[string]any{
			"error": "config_unavailable",
		})
		return
	}
	if !cfg.Enabled || !cfg.ForceFreshEnabled {
		sendEndpointInventoryCommandResult(sender, cmd, false, errEndpointInventoryForceFreshDisabled.Error(), map[string]any{
			"error": "force_fresh_disabled",
		})
		return
	}
	if len(payload.Sources) > 0 {
		if err := ensureEndpointInventorySourcesAllowed(cfg.Sources, payload.Sources); err != nil {
			sendEndpointInventoryCommandResult(sender, cmd, false, err.Error(), map[string]any{
				"error": "source_disabled",
			})
			return
		}
		cfg.Sources = append([]string(nil), payload.Sources...)
	}

	// An explicit operator force-fresh must bypass the cadence floor and
	// source-mtime skip so it always performs a full collection.
	cfg.ForceFreshScan = true

	runTimeout := commandRemainingTimeout(cmd, endpointinventory.ScanTimeout(cfg))
	if runTimeout <= 0 {
		sendEndpointInventoryCommandResult(sender, cmd, false, "command expired", map[string]any{
			"error": "command_expired",
		})
		return
	}
	runCtx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()

	scan, err := endpointinventory.NewRunner(cfg).Run(runCtx)
	if err != nil {
		sendEndpointInventoryCommandResult(sender, cmd, false, err.Error(), map[string]any{
			"error": "scan_failed",
		})
		return
	}
	if err := endpointinventory.WriteSpool(cfg, scan); err != nil {
		sendEndpointInventoryCommandResult(sender, cmd, false, err.Error(), map[string]any{
			"error": "spool_failed",
		})
		return
	}

	response := map[string]any{
		"schema":           "serviceradar.endpoint_inventory.force_fresh_result.v1",
		"scan_id":          scan.ScanID,
		"state":            scan.State,
		"coverage_state":   scan.CoverageState,
		"package_count":    scan.PackageCount,
		"package_set_hash": scan.PackageSetHash,
		"artifact_hash":    scan.ArtifactHash,
		"upload_reason":    scan.UploadReason,
	}
	if payload.Query != nil {
		queryResult, err := endpointinventory.EvaluateCacheQuery(cfg, *payload.Query, time.Now().UTC())
		if err != nil {
			response["query_error"] = err.Error()
		} else {
			response["query"] = queryResult
		}
	}

	sendEndpointInventoryCommandResult(sender, cmd, scan.State != "scan_failed", "endpoint inventory force-fresh scan completed", response)
}

func (p *PushLoop) endpointInventoryCommandConfig() (endpointinventory.Config, error) {
	cfg := endpointinventory.DefaultConfig()
	serverConfig := p.endpointInventoryServerConfig()
	if serverConfig != nil {
		cfg.ProfilePath = serverConfig.effectiveProfilePath()
		cfg.SpoolDir = filepath.Dir(serverConfig.effectiveSpoolPath())
		cfg.CacheDir = serverConfig.effectiveCacheDir()
		cfg.TmpDir = serverConfig.effectiveTmpDir()
	}
	if agentID := p.agentID(); agentID != "" {
		cfg.AgentID = agentID
	}

	if serverConfig != nil {
		loaded, err := endpointinventory.LoadConfig(serverConfig.effectiveConfigPath())
		if err == nil {
			if loaded.AgentID == "" {
				loaded.AgentID = cfg.AgentID
			}
			return loaded, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return cfg, fmt.Errorf("load endpoint inventory config: %w", err)
		}
	}
	if err := endpointinventory.ApplyRuntimeProfileFile(&cfg); err != nil {
		return cfg, fmt.Errorf("load endpoint inventory runtime profile: %w", err)
	}

	return cfg, nil
}

func (p *PushLoop) endpointInventoryServerConfig() *EndpointInventoryStatusConfig {
	if p == nil || p.server == nil {
		return nil
	}

	p.server.mu.RLock()
	defer p.server.mu.RUnlock()
	if p.server.config == nil {
		return nil
	}

	return p.server.config.EndpointInventory
}

func (p *PushLoop) tryAcquireEndpointInventoryFreshScanSlot() bool {
	if p == nil || p.endpointInventoryFreshSem == nil {
		return true
	}

	select {
	case p.endpointInventoryFreshSem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (p *PushLoop) releaseEndpointInventoryFreshScanSlot() {
	if p == nil || p.endpointInventoryFreshSem == nil {
		return
	}

	select {
	case <-p.endpointInventoryFreshSem:
	default:
	}
}

func ensureEndpointInventorySourcesAllowed(enabled []string, requested []string) error {
	allowed := make(map[string]bool, len(enabled))
	for _, source := range enabled {
		allowed[source] = true
	}
	for _, source := range requested {
		if !allowed[source] {
			return fmt.Errorf("%w: %s", errEndpointInventorySourceDisabled, source)
		}
	}

	return nil
}

func sendEndpointInventoryCommandResult(
	sender *controlStreamSender,
	cmd *proto.CommandRequest,
	success bool,
	message string,
	payload any,
) {
	request, err := endpointInventoryCommandResult(cmd, success, message, payload)
	if err != nil {
		request, _ = endpointInventoryCommandResult(cmd, false, err.Error(), map[string]any{
			"error": "payload_too_large",
		})
	}
	_ = sender.Send(request)
}

func endpointInventoryCommandResult(
	cmd *proto.CommandRequest,
	success bool,
	message string,
	payload any,
) (*proto.ControlStreamRequest, error) {
	var payloadJSON []byte
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("marshal endpoint inventory command result: %w", err)
		}
		if len(encoded) > maxEndpointInventoryCommandResultBytes {
			return nil, errEndpointInventoryCommandPayloadTooLarge
		}
		payloadJSON = encoded
	}

	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandResult{
			CommandResult: &proto.CommandResult{
				CommandId:   cmd.CommandId,
				CommandType: cmd.CommandType,
				Success:     success,
				Message:     message,
				PayloadJson: payloadJSON,
				Timestamp:   time.Now().Unix(),
			},
		},
	}, nil
}
