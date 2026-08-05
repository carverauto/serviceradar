// Package browserext scans installed Chromium-family and Firefox browser
// extensions.
//
// Chromium-family browsers (Chrome, Chromium, Brave, Edge, Vivaldi, Arc,
// and similar forks) store each installed extension on disk as:
//
//	<profile>/Extensions/<extension_id>/<version>/manifest.json
//
// The <extension_id> is a 32-character lowercase-letter id. The
// <version> directory name matches the manifest's "version". We read
// only manifest.json — never cookies, IndexedDB, Local Storage, or any
// other profile asset.
//
// Firefox stores per-profile extension metadata in
// <profile>/extensions.json (JSON describing each installed add-on).
// We read that file directly and emit one record per add-on; the
// per-extension XPI/source under <profile>/extensions/ is not opened.
//
// PackageManager is set to "chromium-extension" or "firefox-extension"
// (the install mechanism), not the browser brand. The brand can be
// recovered from source_file, which embeds the per-browser profile path.
package browserext

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

const Ecosystem = model.EcosystemBrowserExtension

// chromiumExtIDLen is the length of a Chromium extension id. Chromium
// generates 32-char ids consisting of letters [a-p] (mapped from hex).
const chromiumExtIDLen = 32

type Scanner struct {
	MaxFileSize int64
	Emit        func(model.Record)
	Diag        func(level, path, msg string)
}

// IsChromiumExtensionManifest reports whether path looks like
// .../Extensions/<id>/<version>/manifest.json under a Chromium-family
// browser profile. It returns the extension id, version directory, and
// the parent profile dir on a positive match.
func IsChromiumExtensionManifest(path string) (ok bool, extID, versionDir, profileDir string) {
	if filepath.Base(path) != "manifest.json" {
		return false, "", "", ""
	}
	versionDir = filepath.Dir(path)      // <version>
	idDir := filepath.Dir(versionDir)    // <extension_id>
	extensionsDir := filepath.Dir(idDir) // Extensions
	profileDir = filepath.Dir(extensionsDir)
	if filepath.Base(extensionsDir) != "Extensions" {
		return false, "", "", ""
	}
	id := filepath.Base(idDir)
	if !isChromiumExtensionID(id) {
		return false, "", "", ""
	}
	return true, id, versionDir, profileDir
}

func isChromiumExtensionID(s string) bool {
	if len(s) != chromiumExtIDLen {
		return false
	}
	for _, r := range s {
		if r < 'a' || r > 'p' {
			return false
		}
	}
	return true
}

// chromiumManifest captures the subset of fields we surface. "name" may
// be a "__MSG_<key>__" placeholder when the extension uses locale
// catalogs; we accept it as-is and fall back to the extension id when it
// can't be resolved.
type chromiumManifest struct {
	Name          string `json:"name"`
	Version       string `json:"version"`
	DefaultLocale string `json:"default_locale"`
}

// ScanChromiumExtension reads <versionDir>/manifest.json and emits one
// record. The Chromium variant (chrome, brave, edge, ...) is not stored
// on the record; it is recoverable from source_file.
func (s *Scanner) ScanChromiumExtension(manifestPath, extID, versionDir, profileDir string, base model.Record) error {
	data, err := s.readBounded(manifestPath)
	if err != nil {
		return err
	}
	var m chromiumManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return fmt.Errorf("parse %s: %w", manifestPath, err)
	}
	name := strings.TrimSpace(m.Name)
	if strings.HasPrefix(name, "__MSG_") && strings.HasSuffix(name, "__") && m.DefaultLocale != "" {
		// Try to resolve from _locales/<default_locale>/messages.json.
		key := strings.TrimSuffix(strings.TrimPrefix(name, "__MSG_"), "__")
		if resolved := s.lookupLocaleMessage(versionDir, m.DefaultLocale, key); resolved != "" {
			name = resolved
		}
	}
	if name == "" {
		// Final fallback so we still emit a record.
		name = extID
	}
	version := strings.TrimSpace(m.Version)
	if version == "" {
		version = filepath.Base(versionDir)
	}
	confidence := "high"
	if version == "" || name == extID {
		confidence = "medium"
	}

	r := base
	r.Ecosystem = Ecosystem
	r.PackageName = name
	r.NormalizedName = strings.ToLower(extID)
	r.Version = version
	r.ProjectPath = profileDir
	// Use the install mechanism rather than the browser brand, so the
	// schema stays consistent with npm/pip/pnpm/etc. The brand can still
	// be recovered from source_file (it embeds the per-browser profile
	// path: ".../Google/Chrome/Default/Extensions/...").
	r.PackageManager = "chromium-extension"
	r.SourceType = "browser-extension"
	r.SourceFile = manifestPath
	r.RootKind = model.RootKindBrowserExtension
	r.Confidence = confidence
	s.Emit(r)
	return nil
}

func (s *Scanner) lookupLocaleMessage(versionDir, locale, key string) string {
	path := filepath.Join(versionDir, "_locales", locale, "messages.json")
	data, err := s.readBounded(path)
	if err != nil {
		// Fall back to en if available and different.
		if locale != "en" {
			return s.lookupLocaleMessage(versionDir, "en", key)
		}
		return ""
	}
	var raw map[string]struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return ""
	}
	// _locales keys are case-insensitive per the extension spec.
	if entry, ok := raw[key]; ok {
		return entry.Message
	}
	lower := strings.ToLower(key)
	for k, v := range raw {
		if strings.ToLower(k) == lower {
			return v.Message
		}
	}
	return ""
}

// firefoxAddon is one entry under "addons" in extensions.json. We only
// read the fields we surface.
type firefoxAddon struct {
	ID            string `json:"id"`
	Version       string `json:"version"`
	DefaultLocale struct {
		Name string `json:"name"`
	} `json:"defaultLocale"`
	Type string `json:"type"`
}

type firefoxExtensionsJSON struct {
	Addons []firefoxAddon `json:"addons"`
}

// IsFirefoxExtensionsJSON returns true if the path is the per-profile
// extensions.json file under a Firefox-family profile (Firefox, LibreWolf,
// Waterfox). The check looks at the slash-normalized parent path for a
// known brand segment so unrelated extensions.json files (e.g. Chromium's
// per-profile preferences) are not picked up.
func IsFirefoxExtensionsJSON(path string) bool {
	if filepath.Base(path) != "extensions.json" {
		return false
	}
	p := filepath.ToSlash(filepath.Dir(path))
	switch {
	case strings.Contains(p, "/Firefox/Profiles/"),
		strings.Contains(p, "/Firefox/"),
		strings.Contains(p, "/LibreWolf/Profiles/"),
		strings.Contains(p, "/Waterfox/Profiles/"),
		strings.Contains(p, "/.mozilla/firefox/"),
		strings.Contains(p, "/.librewolf/"),
		strings.Contains(p, "/.waterfox/"):
		return true
	}
	return false
}

// ScanFirefoxExtensions reads extensions.json and emits one record per
// active add-on (system add-ons and themes are skipped).
func (s *Scanner) ScanFirefoxExtensions(path string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	var doc firefoxExtensionsJSON
	if err := json.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	profileDir := filepath.Dir(path)
	for _, a := range doc.Addons {
		if a.Type != "" && a.Type != "extension" {
			continue
		}
		if a.ID == "" {
			continue
		}
		name := strings.TrimSpace(a.DefaultLocale.Name)
		if name == "" {
			name = a.ID
		}
		r := base
		r.Ecosystem = Ecosystem
		r.PackageName = name
		r.NormalizedName = strings.ToLower(a.ID)
		r.Version = a.Version
		r.ProjectPath = profileDir
		r.PackageManager = "firefox-extension"
		r.SourceType = "browser-extension"
		r.SourceFile = path
		r.RootKind = model.RootKindBrowserExtension
		confidence := "high"
		if a.Version == "" || name == a.ID {
			confidence = "medium"
		}
		r.Confidence = confidence
		s.Emit(r)
	}
	return nil
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
