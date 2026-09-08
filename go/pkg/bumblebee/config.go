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
	defaultProfilePath    = "/var/lib/serviceradar/bumblebee/profile/runtime.json"
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
		ProfilePath:      defaultProfilePath,
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
	if err := applyRuntimeProfileFile(&cfg); err != nil {
		return cfg, err
	}
	applyDefaults(&cfg)

	return cfg, validateConfig(cfg)
}

func applyDefaults(cfg *Config) {
	if cfg.CatalogPath == "" {
		cfg.CatalogPath = defaultCatalogPath
	}
	if cfg.ProfilePath == "" {
		cfg.ProfilePath = defaultProfilePath
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

func applyRuntimeProfileFile(cfg *Config) error {
	if cfg == nil || strings.TrimSpace(cfg.ProfilePath) == "" {
		return nil
	}

	data, err := os.ReadFile(cfg.ProfilePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("read runtime profile: %w", err)
	}

	var profile RuntimeProfile
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&profile); err != nil {
		return fmt.Errorf("decode runtime profile: %w", err)
	}

	ApplyRuntimeProfile(cfg, profile)
	return nil
}

func ApplyRuntimeProfile(cfg *Config, profile RuntimeProfile) {
	if cfg == nil {
		return
	}

	if profile.Enabled != nil {
		cfg.Enabled = *profile.Enabled
	}
	if strings.TrimSpace(profile.AgentID) != "" {
		cfg.AgentID = strings.TrimSpace(profile.AgentID)
	}
	if strings.TrimSpace(profile.DeviceUID) != "" {
		cfg.DeviceUID = strings.TrimSpace(profile.DeviceUID)
	}
	if strings.TrimSpace(profile.CatalogSnapshotRef) != "" {
		cfg.CatalogSnapshotRef = strings.TrimSpace(profile.CatalogSnapshotRef)
	}
	if strings.TrimSpace(profile.ScanTimeout) != "" {
		cfg.ScanTimeout = strings.TrimSpace(profile.ScanTimeout)
	}
	if profile.IncludeHomeRoots != nil {
		cfg.IncludeHomeRoots = *profile.IncludeHomeRoots
	}
	if profile.IncludeRoot != nil {
		cfg.IncludeRoot = *profile.IncludeRoot
	}
	if profile.ExplicitRoots != nil {
		cfg.ExplicitRoots = append([]string(nil), profile.ExplicitRoots...)
	}
	if profile.ExcludeRoots != nil {
		cfg.ExcludeRoots = append([]string(nil), profile.ExcludeRoots...)
	}
	if profile.Ecosystems != nil {
		cfg.Ecosystems = append([]string(nil), profile.Ecosystems...)
	}
	if profile.MaxFindings != nil {
		cfg.MaxFindings = *profile.MaxFindings
	}
	if profile.MaxOutputBytes != nil {
		cfg.MaxOutputBytes = *profile.MaxOutputBytes
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
