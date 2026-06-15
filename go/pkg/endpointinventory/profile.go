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
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

func WriteRuntimeProfile(path string, tmpDir string, profile RuntimeProfile) (bool, error) {
	data, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return false, fmt.Errorf("marshal runtime profile: %w", err)
	}
	data = append(data, '\n')

	existing, err := os.ReadFile(path)
	if err == nil && bytes.Equal(existing, data) {
		return false, nil
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, fmt.Errorf("read existing runtime profile: %w", err)
	}

	// 0770 (group-writable) so both the root scanner and the non-root
	// serviceradar agent can write the runtime profile via the shared
	// serviceradar-group dirs.
	if err := os.MkdirAll(filepath.Dir(path), 0770); err != nil {
		return false, fmt.Errorf("create profile dir: %w", err)
	}
	if err := os.MkdirAll(tmpDir, 0770); err != nil {
		return false, fmt.Errorf("create tmp dir: %w", err)
	}

	tmp, err := os.CreateTemp(tmpDir, ".endpoint-inventory-profile-*.json")
	if err != nil {
		return false, fmt.Errorf("create temp profile: %w", err)
	}

	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return false, fmt.Errorf("write temp profile: %w", err)
	}
	if err := tmp.Chmod(0640); err != nil {
		_ = tmp.Close()
		return false, fmt.Errorf("chmod temp profile: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return false, fmt.Errorf("close temp profile: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return false, fmt.Errorf("rename runtime profile: %w", err)
	}

	return true, nil
}
