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
	"os"
	"path/filepath"
)

func WriteRuntimeProfile(path string, tmpDir string, profile RuntimeProfile) (bool, error) {
	data, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return false, err
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(path), 0770); err != nil {
		return false, err
	}
	if err := os.MkdirAll(tmpDir, 0770); err != nil {
		return false, err
	}

	return writeCatalogAtomic(path, tmpDir, data)
}
