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

package scalibrinventory

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
)

var (
	errScanRootsRequired      = errors.New("scan_roots is required")
	errScaLibrPluginsRequired = errors.New("scalibr_plugins is required")
	errInvalidMaxFileSize     = errors.New("invalid max_file_size")
	errInvalidMaxInodes       = errors.New("invalid max_inodes")
)

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
	// The add-on assignment owns collection cadence. The shared runtime profile
	// still supplies identity and endpoint-inventory policy, but must not silently
	// replace the cadence declared in this producer's staged configuration.
	configuredCadence := cfg.Cadence
	if err := endpointinventory.ApplyRuntimeProfileFile(&cfg.Config); err != nil {
		return cfg, err
	}
	cfg.Cadence = configuredCadence
	applyDefaults(&cfg)

	return cfg, validateConfig(cfg)
}

func applyDefaults(cfg *Config) {
	if cfg.ScannerID == "" {
		cfg.ScannerID = DefaultScannerID
	}
	if cfg.ScannerVersion == "" {
		cfg.ScannerVersion = DefaultScannerVersion
	}
	if len(cfg.ScaLibrPlugins) == 0 {
		cfg.ScaLibrPlugins = []string{"os/dpkg", "os/rpm", "os/apk"}
	}
	if len(cfg.ScanRoots) == 0 {
		cfg.ScanRoots = []string{"/"}
	}
	base := endpointinventory.DefaultConfig()
	if cfg.SpoolDir == "" {
		cfg.SpoolDir = base.SpoolDir
	}
	if cfg.CacheDir == "" {
		cfg.CacheDir = base.CacheDir
	}
	if cfg.TmpDir == "" {
		cfg.TmpDir = base.TmpDir
	}
	if cfg.ProfilePath == "" {
		cfg.ProfilePath = base.ProfilePath
	}
	if cfg.ScanTimeout == "" {
		cfg.ScanTimeout = base.ScanTimeout
	}
	if cfg.Cadence == "" {
		cfg.Cadence = defaultCadence
	}
	if len(cfg.Sources) == 0 {
		cfg.Sources = append([]string(nil), base.Sources...)
	}
	if cfg.UploadJitter == "" {
		cfg.UploadJitter = base.UploadJitter
	}
	if cfg.UploadRetryInitial == "" {
		cfg.UploadRetryInitial = base.UploadRetryInitial
	}
	if cfg.UploadRetryMax == "" {
		cfg.UploadRetryMax = base.UploadRetryMax
	}
	if cfg.UploadRetryMaxAttempts == 0 {
		cfg.UploadRetryMaxAttempts = base.UploadRetryMaxAttempts
	}
	if cfg.CacheStaleThreshold == "" {
		cfg.CacheStaleThreshold = "26h"
	}
	if cfg.MaxPackages == 0 {
		cfg.MaxPackages = base.MaxPackages
	}
	if cfg.MaxOutputBytes == 0 {
		cfg.MaxOutputBytes = base.MaxOutputBytes
	}
}

func validateConfig(cfg Config) error {
	if strings.TrimSpace(cfg.AgentID) == "" {
		return endpointinventory.ErrAgentIDRequired
	}
	if len(cfg.ScanRoots) == 0 {
		return errScanRootsRequired
	}
	if len(cfg.ScaLibrPlugins) == 0 {
		return errScaLibrPluginsRequired
	}
	if cfg.MaxFileSize < 0 {
		return fmt.Errorf("%w: %d", errInvalidMaxFileSize, cfg.MaxFileSize)
	}
	if cfg.MaxInodes < 0 {
		return fmt.Errorf("%w: %d", errInvalidMaxInodes, cfg.MaxInodes)
	}
	base := cfg.Config
	base.Enabled = true
	return endpointinventory.ValidateConfig(base)
}
