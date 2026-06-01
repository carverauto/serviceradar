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

package endpointinventory

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	PackageSourceDpkg = "dpkg"
	PackageSourceRPM  = "rpm"
	PackageSourceAPK  = "apk"

	defaultProfilePath      = "/var/lib/serviceradar/endpoint-inventory/profile/runtime.json"
	defaultSpoolDir         = "/var/lib/serviceradar/endpoint-inventory/spool"
	defaultTmpDir           = "/var/lib/serviceradar/endpoint-inventory/tmp"
	defaultScanTimeout      = "5m"
	defaultOSReleasePath    = "/etc/os-release"
	defaultDpkgStatusPath   = "/var/lib/dpkg/status"
	defaultAPKInstalledPath = "/lib/apk/db/installed"
	defaultRPMPath          = PackageSourceRPM
	defaultMaxPackages      = 100000
	defaultMaxOutputBytes   = 32 * 1024 * 1024
)

var (
	ErrAgentIDRequired      = errors.New("agent_id is required")
	ErrInvalidMaxPackages   = errors.New("invalid max_packages")
	ErrInvalidMaxOutputSize = errors.New("invalid max_output_bytes")
	ErrUnsupportedSource    = errors.New("unsupported source")
)

func DefaultConfig() Config {
	return Config{
		Enabled:          false,
		ProfilePath:      defaultProfilePath,
		SpoolDir:         defaultSpoolDir,
		TmpDir:           defaultTmpDir,
		ScanTimeout:      defaultScanTimeout,
		OSReleasePath:    defaultOSReleasePath,
		DpkgStatusPath:   defaultDpkgStatusPath,
		APKInstalledPath: defaultAPKInstalledPath,
		RPMPath:          defaultRPMPath,
		Sources:          defaultPackageSources(),
		MaxPackages:      defaultMaxPackages,
		MaxOutputBytes:   defaultMaxOutputBytes,
	}
}

func defaultPackageSources() []string {
	return []string{PackageSourceDpkg, PackageSourceRPM, PackageSourceAPK}
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
	if cfg.ProfilePath == "" {
		cfg.ProfilePath = defaultProfilePath
	}
	if cfg.SpoolDir == "" {
		cfg.SpoolDir = defaultSpoolDir
	}
	if cfg.TmpDir == "" {
		cfg.TmpDir = defaultTmpDir
	}
	if cfg.ScanTimeout == "" {
		cfg.ScanTimeout = defaultScanTimeout
	}
	if cfg.OSReleasePath == "" {
		cfg.OSReleasePath = defaultOSReleasePath
	}
	if cfg.DpkgStatusPath == "" {
		cfg.DpkgStatusPath = defaultDpkgStatusPath
	}
	if cfg.APKInstalledPath == "" {
		cfg.APKInstalledPath = defaultAPKInstalledPath
	}
	if cfg.RPMPath == "" {
		cfg.RPMPath = defaultRPMPath
	}
	if len(cfg.Sources) == 0 {
		cfg.Sources = defaultPackageSources()
	}
	if cfg.MaxPackages <= 0 {
		cfg.MaxPackages = defaultMaxPackages
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
	if strings.TrimSpace(profile.ScanTimeout) != "" {
		cfg.ScanTimeout = strings.TrimSpace(profile.ScanTimeout)
	}
	if profile.Sources != nil {
		cfg.Sources = append([]string(nil), profile.Sources...)
	}
	if profile.MaxPackages != nil {
		cfg.MaxPackages = *profile.MaxPackages
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
	if cfg.MaxPackages <= 0 {
		return fmt.Errorf("%w: %d", ErrInvalidMaxPackages, cfg.MaxPackages)
	}
	if cfg.MaxOutputBytes <= 0 {
		return fmt.Errorf("%w: %d", ErrInvalidMaxOutputSize, cfg.MaxOutputBytes)
	}
	for _, source := range cfg.Sources {
		switch source {
		case PackageSourceDpkg, PackageSourceRPM, PackageSourceAPK:
		default:
			return fmt.Errorf("%w: %s", ErrUnsupportedSource, source)
		}
	}

	return nil
}

func ScanTimeout(cfg Config) time.Duration {
	timeout, err := time.ParseDuration(cfg.ScanTimeout)
	if err != nil || timeout <= 0 {
		return 5 * time.Minute
	}

	return timeout
}
