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

	defaultProfilePath         = "/var/lib/serviceradar/endpoint-inventory/profile/runtime.json"
	defaultSpoolDir            = "/var/lib/serviceradar/endpoint-inventory/spool"
	defaultCacheDir            = "/var/lib/serviceradar/endpoint-inventory/cache"
	defaultTmpDir              = "/var/lib/serviceradar/endpoint-inventory/tmp"
	defaultScanTimeout         = "5m"
	defaultOSReleasePath       = "/etc/os-release"
	defaultDpkgStatusPath      = "/var/lib/dpkg/status"
	defaultAPKInstalledPath    = "/lib/apk/db/installed"
	defaultRPMPath             = PackageSourceRPM
	defaultCadence             = "12h"
	defaultMaxPackages         = 100000
	defaultMaxOutputBytes      = MaxSpoolPayloadBytes
	defaultFullScanInterval    = 24
	defaultUploadJitter        = "0s"
	defaultUploadRetryInitial  = "5m"
	defaultUploadRetryMax      = "1h"
	defaultUploadRetryAttempts = 5
	defaultCacheStale          = "26h"
)

var (
	ErrAgentIDRequired         = errors.New("agent_id is required")
	ErrInvalidMaxPackages      = errors.New("invalid max_packages")
	ErrInvalidMaxOutputSize    = errors.New("invalid max_output_bytes")
	ErrInvalidDuration         = errors.New("invalid duration")
	ErrInvalidRetryRange       = errors.New("invalid upload_retry_max: must be greater than or equal to upload_retry_initial")
	ErrInvalidRetryAttempts    = errors.New("invalid upload_retry_max_attempts")
	ErrInvalidFullScanInterval = errors.New("invalid force_full_scan_interval")
	ErrUnsupportedSource       = errors.New("unsupported source")
)

func DefaultConfig() Config {
	return Config{
		Enabled:                false,
		ProfilePath:            defaultProfilePath,
		SpoolDir:               defaultSpoolDir,
		CacheDir:               defaultCacheDir,
		TmpDir:                 defaultTmpDir,
		ScanTimeout:            defaultScanTimeout,
		OSReleasePath:          defaultOSReleasePath,
		DpkgStatusPath:         defaultDpkgStatusPath,
		APKInstalledPath:       defaultAPKInstalledPath,
		RPMPath:                defaultRPMPath,
		RPMDatabasePaths:       defaultRPMDatabasePaths(),
		Sources:                defaultPackageSources(),
		Cadence:                defaultCadence,
		ForceFullScanInterval:  defaultFullScanInterval,
		UploadJitter:           defaultUploadJitter,
		UploadRetryInitial:     defaultUploadRetryInitial,
		UploadRetryMax:         defaultUploadRetryMax,
		UploadRetryMaxAttempts: defaultUploadRetryAttempts,
		CacheStaleThreshold:    defaultCacheStale,
		MaxPackages:            defaultMaxPackages,
		MaxOutputBytes:         defaultMaxOutputBytes,
	}
}

func defaultPackageSources() []string {
	return []string{PackageSourceDpkg, PackageSourceRPM, PackageSourceAPK}
}

func defaultRPMDatabasePaths() []string {
	return []string{
		"/usr/lib/sysimage/rpm/rpmdb.sqlite",
		"/var/lib/rpm/rpmdb.sqlite",
		"/var/lib/rpm/Packages",
		"/var/lib/rpm",
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
	if cfg.ProfilePath == "" {
		cfg.ProfilePath = defaultProfilePath
	}
	if cfg.SpoolDir == "" {
		cfg.SpoolDir = defaultSpoolDir
	}
	if cfg.CacheDir == "" {
		cfg.CacheDir = defaultCacheDir
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
	if len(cfg.RPMDatabasePaths) == 0 {
		cfg.RPMDatabasePaths = defaultRPMDatabasePaths()
	}
	if len(cfg.Sources) == 0 {
		cfg.Sources = defaultPackageSources()
	}
	if cfg.Cadence == "" {
		cfg.Cadence = defaultCadence
	}
	if cfg.ForceFullScanInterval == 0 {
		cfg.ForceFullScanInterval = defaultFullScanInterval
	}
	if cfg.UploadJitter == "" {
		cfg.UploadJitter = defaultUploadJitter
	}
	if cfg.UploadRetryInitial == "" {
		cfg.UploadRetryInitial = defaultUploadRetryInitial
	}
	if cfg.UploadRetryMax == "" {
		cfg.UploadRetryMax = defaultUploadRetryMax
	}
	if cfg.UploadRetryMaxAttempts == 0 {
		cfg.UploadRetryMaxAttempts = defaultUploadRetryAttempts
	}
	if cfg.CacheStaleThreshold == "" {
		cfg.CacheStaleThreshold = defaultCacheStale
	}
	if cfg.MaxPackages == 0 {
		cfg.MaxPackages = defaultMaxPackages
	}
	if cfg.MaxOutputBytes == 0 {
		cfg.MaxOutputBytes = defaultMaxOutputBytes
	}
}

func applyRuntimeProfileFile(cfg *Config) error {
	if cfg == nil || strings.TrimSpace(cfg.ProfilePath) == "" {
		return nil
	}

	profile, err := LoadRuntimeProfile(cfg.ProfilePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}

	ApplyRuntimeProfile(cfg, profile)
	return nil
}

func ApplyRuntimeProfileFile(cfg *Config) error {
	return applyRuntimeProfileFile(cfg)
}

func LoadRuntimeProfile(path string) (RuntimeProfile, error) {
	var profile RuntimeProfile
	data, err := os.ReadFile(path)
	if err != nil {
		return profile, err
	}

	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&profile); err != nil {
		return profile, fmt.Errorf("decode runtime profile: %w", err)
	}

	return profile, nil
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
	if strings.TrimSpace(profile.Cadence) != "" {
		cfg.Cadence = strings.TrimSpace(profile.Cadence)
	}
	if profile.CollectPaths != nil {
		cfg.CollectPaths = *profile.CollectPaths
	}
	if profile.CollectFileHashes != nil {
		cfg.CollectFileHashes = *profile.CollectFileHashes
	}
	if profile.ForceFreshEnabled != nil {
		cfg.ForceFreshEnabled = *profile.ForceFreshEnabled
	}
	if profile.ForceFullScanInterval != nil {
		cfg.ForceFullScanInterval = *profile.ForceFullScanInterval
	}
	if strings.TrimSpace(profile.UploadJitter) != "" {
		cfg.UploadJitter = strings.TrimSpace(profile.UploadJitter)
	}
	if strings.TrimSpace(profile.UploadRetryInitial) != "" {
		cfg.UploadRetryInitial = strings.TrimSpace(profile.UploadRetryInitial)
	}
	if strings.TrimSpace(profile.UploadRetryMax) != "" {
		cfg.UploadRetryMax = strings.TrimSpace(profile.UploadRetryMax)
	}
	if profile.UploadRetryMaxAttempts != nil {
		cfg.UploadRetryMaxAttempts = *profile.UploadRetryMaxAttempts
	}
	if strings.TrimSpace(profile.CacheStaleThreshold) != "" {
		cfg.CacheStaleThreshold = strings.TrimSpace(profile.CacheStaleThreshold)
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
	if timeout, err := time.ParseDuration(cfg.ScanTimeout); err != nil {
		return fmt.Errorf("invalid scan_timeout: %w", err)
	} else if timeout <= 0 {
		return fmt.Errorf("invalid scan_timeout: %w", ErrInvalidDuration)
	}
	if cadence, err := time.ParseDuration(cfg.Cadence); err != nil {
		return fmt.Errorf("invalid cadence: %w", err)
	} else if cadence <= 0 {
		return fmt.Errorf("invalid cadence: %w", ErrInvalidDuration)
	}
	if jitter, err := time.ParseDuration(cfg.UploadJitter); err != nil {
		return fmt.Errorf("invalid upload_jitter: %w", err)
	} else if jitter < 0 {
		return fmt.Errorf("invalid upload_jitter: %w", ErrInvalidDuration)
	}
	if retryInitial, err := time.ParseDuration(cfg.UploadRetryInitial); err != nil {
		return fmt.Errorf("invalid upload_retry_initial: %w", err)
	} else if retryInitial <= 0 {
		return fmt.Errorf("invalid upload_retry_initial: %w", ErrInvalidDuration)
	}
	if retryMax, err := time.ParseDuration(cfg.UploadRetryMax); err != nil {
		return fmt.Errorf("invalid upload_retry_max: %w", err)
	} else if retryMax <= 0 {
		return fmt.Errorf("invalid upload_retry_max: %w", ErrInvalidDuration)
	} else if retryInitial, initialErr := time.ParseDuration(cfg.UploadRetryInitial); initialErr == nil && retryMax < retryInitial {
		return ErrInvalidRetryRange
	}
	if cfg.UploadRetryMaxAttempts <= 0 {
		return fmt.Errorf("%w: %d", ErrInvalidRetryAttempts, cfg.UploadRetryMaxAttempts)
	}
	if cfg.ForceFullScanInterval <= 0 {
		return fmt.Errorf("%w: %d", ErrInvalidFullScanInterval, cfg.ForceFullScanInterval)
	}
	if cfg.MaxPackages <= 0 {
		return fmt.Errorf("%w: %d", ErrInvalidMaxPackages, cfg.MaxPackages)
	}
	if cfg.MaxOutputBytes <= 0 || cfg.MaxOutputBytes > MaxSpoolPayloadBytes {
		return fmt.Errorf("%w: %d", ErrInvalidMaxOutputSize, cfg.MaxOutputBytes)
	}
	if stale, err := time.ParseDuration(cfg.CacheStaleThreshold); err != nil {
		return fmt.Errorf("invalid cache_stale_threshold: %w", err)
	} else if stale <= 0 {
		return fmt.Errorf("invalid cache_stale_threshold: %w", ErrInvalidDuration)
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

// ValidateConfig validates an effective endpoint-inventory configuration.
// Callers embedding Config should apply their defaults before invoking it.
func ValidateConfig(cfg Config) error {
	return validateConfig(cfg)
}

func ScanTimeout(cfg Config) time.Duration {
	timeout, err := time.ParseDuration(cfg.ScanTimeout)
	if err != nil || timeout <= 0 {
		return 5 * time.Minute
	}

	return timeout
}
