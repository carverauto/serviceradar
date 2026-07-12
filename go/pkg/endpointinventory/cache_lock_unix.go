//go:build linux || darwin || freebsd || netbsd || openbsd || dragonfly

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

package endpointinventory

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

const cacheManifestLockFileName = ".manifest.lock"

//nolint:gochecknoglobals // Manifest read-modify-write operations require one process-wide lock.
var cacheManifestProcessLock sync.Mutex

func withCacheManifestLock(cfg Config, fn func() error) error {
	cacheManifestProcessLock.Lock()
	defer cacheManifestProcessLock.Unlock()

	if err := os.MkdirAll(cfg.CacheDir, 0770); err != nil {
		return fmt.Errorf("create endpoint inventory cache dir: %w", err)
	}

	lockPath := filepath.Join(cfg.CacheDir, cacheManifestLockFileName)
	lockFile, err := os.OpenFile(lockPath, os.O_RDONLY|os.O_CREATE, 0660)
	if err != nil {
		return fmt.Errorf("open endpoint inventory cache lock: %w", err)
	}
	defer func() { _ = lockFile.Close() }()

	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("lock endpoint inventory cache manifest: %w", err)
	}
	defer func() { _ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN) }()

	return fn()
}
