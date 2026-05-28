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

package bumblebee

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	defaultCatalogPath    = "/var/lib/serviceradar/bumblebee/catalog/current"
	defaultSpoolDir       = "/var/lib/serviceradar/bumblebee/spool"
	defaultTmpDir         = "/var/lib/serviceradar/bumblebee/tmp"
	defaultPasswdPath     = "/etc/passwd"
	defaultScanTimeout    = "10m"
	defaultMaxFindings    = 1000
	defaultMaxOutputBytes = 32 * 1024 * 1024
)

var ErrAgentIDRequired = errors.New("agent_id is required")

func DefaultConfig() Config {
	return Config{
		Enabled:          false,
		CatalogPath:      defaultCatalogPath,
		SpoolDir:         defaultSpoolDir,
		TmpDir:           defaultTmpDir,
		PasswdPath:       defaultPasswdPath,
		ScanTimeout:      defaultScanTimeout,
		IncludeHomeRoots: true,
		IncludeRoot:      true,
		MaxFindings:      defaultMaxFindings,
		MaxOutputBytes:   defaultMaxOutputBytes,
	}
}

func LoadConfig(path string) (Config, error) {
	cfg := DefaultConfig()

	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}

	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("decode config: %w", err)
	}

	applyDefaults(&cfg)

	return cfg, validateConfig(cfg)
}

func applyDefaults(cfg *Config) {
	if cfg.CatalogPath == "" {
		cfg.CatalogPath = defaultCatalogPath
	}
	if cfg.SpoolDir == "" {
		cfg.SpoolDir = defaultSpoolDir
	}
	if cfg.TmpDir == "" {
		cfg.TmpDir = defaultTmpDir
	}
	if cfg.PasswdPath == "" {
		cfg.PasswdPath = defaultPasswdPath
	}
	if cfg.ScanTimeout == "" {
		cfg.ScanTimeout = defaultScanTimeout
	}
	if cfg.MaxFindings <= 0 {
		cfg.MaxFindings = defaultMaxFindings
	}
	if cfg.MaxOutputBytes <= 0 {
		cfg.MaxOutputBytes = defaultMaxOutputBytes
	}
}

func validateConfig(cfg Config) error {
	if !cfg.Enabled {
		return nil
	}

	if strings.TrimSpace(cfg.AgentID) == "" {
		return ErrAgentIDRequired
	}

	if _, err := time.ParseDuration(cfg.ScanTimeout); err != nil {
		return fmt.Errorf("invalid scan_timeout: %w", err)
	}

	return nil
}

func ScanTimeout(cfg Config) time.Duration {
	timeout, err := time.ParseDuration(cfg.ScanTimeout)
	if err != nil || timeout <= 0 {
		return 10 * time.Minute
	}

	return timeout
}
