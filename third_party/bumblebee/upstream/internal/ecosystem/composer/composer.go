// Package composer scans composer.lock and installed-package metadata for
// the PHP Composer / Packagist ecosystem.
//
// composer.lock is JSON. The schema we read is:
//
//	{
//	  "packages":     [{ "name": "...", "version": "...", ... }],
//	  "packages-dev": [{ "name": "...", "version": "...", ... }]
//	}
//
// We also recognize vendor/composer/installed.json which Composer writes
// alongside the installed vendor/ tree and which uses the same per-package
// shape under either an array root (Composer v1) or {"packages":[...]} (v2).
package composer

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/model"
)

const Ecosystem = model.EcosystemPackagist

type Scanner struct {
	MaxFileSize int64
	Emit        func(model.Record)
	Diag        func(level, path, msg string)
}

func IsComposerLock(base string) bool { return base == "composer.lock" }
func IsInstalledJSON(path string) bool {
	// vendor/composer/installed.json
	return filepath.Base(path) == "installed.json" &&
		filepath.Base(filepath.Dir(path)) == "composer" &&
		filepath.Base(filepath.Dir(filepath.Dir(path))) == "vendor"
}

type packageEntry struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

func (s *Scanner) ScanComposerLock(path string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	var lf struct {
		Packages    []packageEntry `json:"packages"`
		PackagesDev []packageEntry `json:"packages-dev"`
	}
	if err := json.Unmarshal(data, &lf); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	projectPath := filepath.Dir(path)
	s.emitEntries(lf.Packages, path, projectPath, "prod", "composer-lock", base)
	s.emitEntries(lf.PackagesDev, path, projectPath, "dev", "composer-lock", base)
	return nil
}

func (s *Scanner) ScanInstalledJSON(path string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	projectPath := filepath.Dir(filepath.Dir(filepath.Dir(path))) // strip vendor/composer/
	// Try v2 form first. A successful v2 parse (object with a "packages"
	// key) is authoritative even when the array is empty; only fall back
	// to v1 (root array) when the v2 envelope is not present at all, so
	// an empty v2 file does not produce a confusing v1 parse error.
	var v2probe struct {
		Packages *[]packageEntry `json:"packages"`
	}
	if err := json.Unmarshal(data, &v2probe); err == nil && v2probe.Packages != nil {
		s.emitEntries(*v2probe.Packages, path, projectPath, "", "composer-installed", base)
		return nil
	}
	var entries []packageEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	s.emitEntries(entries, path, projectPath, "", "composer-installed", base)
	return nil
}

func (s *Scanner) emitEntries(entries []packageEntry, source, projectPath, scope, sourceType string, base model.Record) {
	for _, e := range entries {
		if e.Name == "" || e.Version == "" {
			continue
		}
		r := base
		r.Ecosystem = Ecosystem
		r.PackageName = e.Name
		r.NormalizedName = strings.ToLower(e.Name)
		r.Version = e.Version
		r.ProjectPath = projectPath
		r.PackageManager = "composer"
		r.SourceType = sourceType
		r.SourceFile = source
		r.InstallScope = scope
		if sourceType == "composer-installed" {
			r.Confidence = "medium"
		} else {
			r.Confidence = "high"
		}
		s.Emit(r)
	}
}

func (s *Scanner) readBounded(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}
	if s.MaxFileSize > 0 && info.Size() > s.MaxFileSize {
		if s.Diag != nil {
			s.Diag("warn", path, fmt.Sprintf("skipping: size %d exceeds max %d", info.Size(), s.MaxFileSize))
		}
		return nil, fmt.Errorf("file %s exceeds max size %d", path, s.MaxFileSize)
	}
	return io.ReadAll(f)
}
