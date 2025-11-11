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
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
)

const defaultAgentID = "default-agent"

// SeedCheckerConfigsFromDisk pushes checker definitions from the filesystem into KV if they are missing.
func SeedCheckerConfigsFromDisk(
	ctx context.Context,
	kvMgr *config.KVManager,
	cfg *ServerConfig,
	configPath string,
	log logger.Logger,
) error {
	if cfg == nil || cfg.CheckersDir == "" {
		return nil
	}
	if log == nil {
		log = logger.NewTestLogger()
	}
	if kvMgr == nil {
		log.Debug().Msg("Skipping checker seed: KV manager unavailable")
		return nil
	}

	agentID, err := ResolveAgentID(configPath, cfg.AgentID)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to resolve agent_id for checker seeding")
		return err
	}
	cfg.AgentID = agentID

	log.Info().
		Str("agent_id", agentID).
		Str("dir", cfg.CheckersDir).
		Msg("Seeding checker configs into KV")

	entries, err := os.ReadDir(cfg.CheckersDir)
	if err != nil {
		return fmt.Errorf("read checker directory: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}

		path := filepath.Join(cfg.CheckersDir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			log.Warn().Err(err).Str("file", path).Msg("Skipping checker seed; failed reading file")
			continue
		}

		key := fmt.Sprintf("agents/%s/checkers/%s", agentID, entry.Name())
		created, err := kvMgr.PutIfAbsent(ctx, key, data, 0)
		if err != nil {
			log.Warn().Err(err).Str("kv_key", key).Msg("Failed to seed checker config")
			continue
		}

		if created {
			log.Info().Str("kv_key", key).Str("file", path).Msg("Seeded checker config into KV")
		} else {
			log.Debug().Str("kv_key", key).Msg("Checker config already present in KV; skipping seed")
		}
	}

	return nil
}

// ResolveAgentID determines the canonical agent_id by checking current config, env vars, and config files.
func ResolveAgentID(configPath, current string) (string, error) {
	candidate := strings.TrimSpace(current)
	if candidate != "" && candidate != defaultAgentID {
		return candidate, nil
	}
	if envID := strings.TrimSpace(os.Getenv("AGENT_ID")); envID != "" && envID != defaultAgentID {
		return envID, nil
	}
	path := strings.TrimSpace(configPath)
	if path == "" {
		return "", fmt.Errorf("agent_id not set and config path unavailable")
	}

	payload, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read config for agent_id: %w", err)
	}
	var stub struct {
		AgentID string `json:"agent_id"`
	}
	if err := json.Unmarshal(payload, &stub); err != nil {
		return "", fmt.Errorf("parse agent_id from %s: %w", path, err)
	}
	stub.AgentID = strings.TrimSpace(stub.AgentID)
	if stub.AgentID == "" || stub.AgentID == defaultAgentID {
		return "", fmt.Errorf("agent_id missing in %s", path)
	}
	return stub.AgentID, nil
}
