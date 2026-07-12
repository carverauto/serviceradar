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
	"path/filepath"
)

const CacheManifestFileName = "manifest.json"

var (
	ErrCacheRefreshRequired     = errors.New("endpoint inventory cache changed during scan")
	ErrIncompleteFullScan       = errors.New("endpoint inventory full scan payload is incomplete")
	ErrPendingUploadUnavailable = errors.New("endpoint inventory pending upload is unavailable")
	ErrStaleFullScan            = errors.New("endpoint inventory full scan is older than the committed cache")
)

func CacheManifestPath(cacheDir string) string {
	return filepath.Join(cacheDir, CacheManifestFileName)
}

func ReadCacheManifest(cfg Config) (*InventoryCacheManifest, error) {
	return readCacheManifestUnlocked(cfg)
}

func readCacheManifestUnlocked(cfg Config) (*InventoryCacheManifest, error) {
	data, err := os.ReadFile(CacheManifestPath(cfg.CacheDir))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}

		return nil, fmt.Errorf("read endpoint inventory cache manifest: %w", err)
	}

	var manifest InventoryCacheManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("decode endpoint inventory cache manifest: %w", err)
	}

	return &manifest, nil
}

func WriteCacheManifest(cfg Config, manifest *InventoryCacheManifest) error {
	if manifest == nil {
		return nil
	}

	return withCacheManifestLock(cfg, func() error {
		return writeCacheManifestUnlocked(cfg, manifest)
	})
}

func writeCacheManifestUnlocked(cfg Config, manifest *InventoryCacheManifest) error {
	// 0770 (group-writable) so both the root scanner and the non-root
	// serviceradar agent can write the cache manifest via the shared
	// serviceradar-group dirs.
	if err := os.MkdirAll(cfg.CacheDir, 0770); err != nil {
		return fmt.Errorf("create endpoint inventory cache dir: %w", err)
	}
	if err := os.MkdirAll(cfg.TmpDir, 0770); err != nil {
		return fmt.Errorf("create tmp dir: %w", err)
	}

	if err := writeJSONAtomic(CacheManifestPath(cfg.CacheDir), cfg.TmpDir, cfg.MaxOutputBytes, manifest); err != nil {
		return fmt.Errorf("write endpoint inventory cache manifest: %w", err)
	}

	return nil
}

// ReadCacheManifestAndPending returns a manifest snapshot and, when present,
// the exact pending payload named by that snapshot. The shared lock prevents an
// acknowledgement or scanner commit from changing either side mid-read.
func ReadCacheManifestAndPending(cfg Config) (*InventoryCacheManifest, []byte, error) {
	var (
		manifest *InventoryCacheManifest
		pending  []byte
	)
	err := withCacheManifestLock(cfg, func() error {
		var err error
		manifest, err = readCacheManifestUnlocked(cfg)
		if err != nil || manifest == nil || manifest.PendingUpload == nil {
			return err
		}

		_, pending, err = readMatchingPendingPayloadUnlocked(cfg, manifest)
		return err
	})

	return manifest, pending, err
}
