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
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const CatalogAssignmentSchema = "serviceradar.bumblebee.catalog_assignment.v1"

var (
	ErrCatalogObjectStoreUnavailable = errors.New("bumblebee catalog object store unavailable")
	ErrCatalogAssignmentIncomplete   = errors.New("bumblebee catalog assignment incomplete")
	ErrCatalogHashMismatch           = errors.New("bumblebee catalog sha256 mismatch")
)

type ObjectDownloader interface {
	DownloadObject(ctx context.Context, key string) ([]byte, error)
}

type CatalogAssignment struct {
	SchemaVersion  string `json:"schema_version,omitempty"`
	SnapshotRef    string `json:"snapshot_ref"`
	CatalogVersion string `json:"catalog_version,omitempty"`
	SourceRevision string `json:"source_revision,omitempty"`
	ObjectKey      string `json:"object_key"`
	SHA256         string `json:"sha256"`
	SizeBytes      int64  `json:"size_bytes,omitempty"`
	DownloadURL    string `json:"download_url,omitempty"`
	DownloadToken  string `json:"download_token,omitempty"`
}

type CatalogStageResult struct {
	Changed     bool
	SnapshotRef string
	Path        string
	SHA256      string
}

func LoadCatalogAssignmentMetadata(catalogPath string) (CatalogAssignment, error) {
	var assignment CatalogAssignment

	data, err := os.ReadFile(catalogPath + ".metadata.json")
	if err != nil {
		return assignment, err
	}
	if err := json.Unmarshal(data, &assignment); err != nil {
		return assignment, err
	}

	return assignment, nil
}

func StageCatalogAssignment(
	ctx context.Context,
	downloader ObjectDownloader,
	catalogPath string,
	tmpDir string,
	assignment CatalogAssignment,
) (CatalogStageResult, error) {
	result := CatalogStageResult{
		SnapshotRef: strings.TrimSpace(assignment.SnapshotRef),
		Path:        catalogPath,
		SHA256:      strings.ToLower(strings.TrimSpace(assignment.SHA256)),
	}

	if strings.TrimSpace(assignment.ObjectKey) == "" ||
		result.SnapshotRef == "" ||
		result.SHA256 == "" {
		return result, ErrCatalogAssignmentIncomplete
	}

	if downloader == nil {
		return result, ErrCatalogObjectStoreUnavailable
	}

	data, err := downloader.DownloadObject(ctx, assignment.ObjectKey)
	if err != nil {
		return result, err
	}

	if got := digest(data); got != result.SHA256 {
		return result, fmt.Errorf("%w: got %s want %s", ErrCatalogHashMismatch, got, result.SHA256)
	}

	if err := os.MkdirAll(filepath.Dir(catalogPath), 0770); err != nil {
		return result, err
	}
	if err := os.MkdirAll(tmpDir, 0770); err != nil {
		return result, err
	}

	snapshotPath := filepath.Join(filepath.Dir(catalogPath), safeCatalogFilename(result.SnapshotRef)+".json")
	if changed, err := writeCatalogAtomic(snapshotPath, tmpDir, data); err != nil {
		return result, err
	} else if changed {
		result.Changed = true
	}

	if changed, err := writeCatalogAtomic(catalogPath, tmpDir, data); err != nil {
		return result, err
	} else if changed {
		result.Changed = true
	}

	meta, err := json.MarshalIndent(assignment, "", "  ")
	if err != nil {
		return result, err
	}
	meta = append(meta, '\n')

	if changed, err := writeCatalogAtomic(catalogPath+".metadata.json", tmpDir, meta); err != nil {
		return result, err
	} else if changed {
		result.Changed = true
	}

	return result, nil
}

func writeCatalogAtomic(path string, tmpDir string, data []byte) (bool, error) {
	if current, err := os.ReadFile(path); err == nil && string(current) == string(data) {
		return false, nil
	}

	tmp, err := os.CreateTemp(tmpDir, ".bumblebee-catalog-*")
	if err != nil {
		return false, err
	}

	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Chmod(0640); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return false, err
	}

	return true, nil
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func safeCatalogFilename(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	var b strings.Builder

	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '.', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}

	name := strings.Trim(b.String(), "-")
	if name == "" {
		return "catalog"
	}

	return name
}
