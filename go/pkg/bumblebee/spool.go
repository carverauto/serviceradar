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
	"fmt"
	"os"
	"path/filepath"
)

const LatestFileName = "latest.json"

func LatestPath(spoolDir string) string {
	return filepath.Join(spoolDir, LatestFileName)
}

func ReadLatest(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func WriteSpool(cfg Config, payload *ScanPayload) error {
	if payload == nil {
		return nil
	}

	if err := os.MkdirAll(cfg.SpoolDir, 0750); err != nil {
		return fmt.Errorf("create spool dir: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(cfg.SpoolDir, "runs"), 0750); err != nil {
		return fmt.Errorf("create run spool dir: %w", err)
	}
	if err := os.MkdirAll(cfg.TmpDir, 0750); err != nil {
		return fmt.Errorf("create tmp dir: %w", err)
	}

	if err := writeJSONAtomic(LatestPath(cfg.SpoolDir), cfg.TmpDir, payload); err != nil {
		return err
	}

	if payload.RunID != "" {
		runPath := filepath.Join(cfg.SpoolDir, "runs", payload.RunID+".json")
		if err := writeJSONAtomic(runPath, cfg.TmpDir, payload); err != nil {
			return err
		}
	}

	return nil
}

func writeJSONAtomic(path string, tmpDir string, payload *ScanPayload) error {
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal spool payload: %w", err)
	}
	data = append(data, '\n')

	tmp, err := os.CreateTemp(tmpDir, ".bumblebee-*.json")
	if err != nil {
		return fmt.Errorf("create temp spool file: %w", err)
	}

	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp spool file: %w", err)
	}
	if err := tmp.Chmod(0640); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("chmod temp spool file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp spool file: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename spool file: %w", err)
	}

	return nil
}
