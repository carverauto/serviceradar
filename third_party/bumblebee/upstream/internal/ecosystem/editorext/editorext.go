// Package editorext scans installed VS Code, Cursor, Windsurf, and VSCodium
// extensions.
//
// All four clients store extensions in a per-user directory whose entries
// look like:
//
//	<root>/<publisher>.<name>-<version>[-<platform>]/package.json
//
// We dispatch only on paths whose parent directory matches one of those
// known extension roots so plain node_modules package.json files are not
// re-emitted as extensions. Only "name", "version", and "publisher" are
// read; v0.1's slim schema does not emit `engines.vscode` on records.
package editorext

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

const Ecosystem = model.EcosystemEditorExtension

type Scanner struct {
	MaxFileSize int64
	Emit        func(model.Record)
	Diag        func(level, path, msg string)
}

// extensionRootSegments are the trailing path segments (joined with "/") of
// known per-user extension roots. The walker tests path containment against
// these so we don't need to enumerate every cross-platform absolute root.
var extensionRootSegments = []string{
	".vscode/extensions",
	".vscode-server/extensions",
	".vscode-insiders/extensions",
	".cursor/extensions",
	".cursor-server/extensions",
	".windsurf/extensions",
	".windsurf-server/extensions",
	".vscodium/extensions",
}

// IsExtensionPackageJSON returns (true, extensionRoot, extensionDir) if path
// looks like .../{known-extensions-root}/<id>/package.json.
func IsExtensionPackageJSON(path string) (bool, string, string) {
	if filepath.Base(path) != "package.json" {
		return false, "", ""
	}
	dir := filepath.Dir(path)   // <id> dir
	parent := filepath.Dir(dir) // extensions root
	parentSlash := filepath.ToSlash(parent)
	for _, seg := range extensionRootSegments {
		if strings.HasSuffix(parentSlash, "/"+seg) || parentSlash == seg {
			return true, parent, dir
		}
	}
	return false, "", ""
}

type extPackageJSON struct {
	Name      string `json:"name"`
	Version   string `json:"version"`
	Publisher string `json:"publisher"`
}

func (s *Scanner) ScanExtension(path, extRoot, extDir string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	var pj extPackageJSON
	if err := json.Unmarshal(data, &pj); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	if pj.Name == "" || pj.Version == "" {
		// Best-effort fallback to dir name "publisher.name-version".
		bn := filepath.Base(extDir)
		if i := strings.LastIndexByte(bn, '-'); i > 0 {
			id, ver := bn[:i], bn[i+1:]
			if pj.Version == "" {
				pj.Version = ver
			}
			if pj.Name == "" {
				if dot := strings.IndexByte(id, '.'); dot > 0 {
					pj.Publisher = id[:dot]
					pj.Name = id[dot+1:]
				} else {
					pj.Name = id
				}
			}
		}
	}
	if pj.Name == "" || pj.Version == "" {
		return fmt.Errorf("incomplete extension package.json at %s", path)
	}

	fullID := pj.Name
	if pj.Publisher != "" {
		fullID = pj.Publisher + "." + pj.Name
	}

	host := hostFromExtRoot(extRoot)

	r := base
	r.Ecosystem = Ecosystem
	r.PackageName = fullID
	r.NormalizedName = strings.ToLower(fullID)
	r.Version = pj.Version
	r.ProjectPath = extRoot
	r.PackageManager = host
	r.SourceType = "editor-extension"
	r.SourceFile = path
	r.Confidence = "high"
	s.Emit(r)
	return nil
}

func hostFromExtRoot(extRoot string) string {
	p := filepath.ToSlash(extRoot)
	switch {
	case strings.Contains(p, "/.cursor"):
		return "cursor"
	case strings.Contains(p, "/.windsurf"):
		return "windsurf"
	case strings.Contains(p, "/.vscodium"):
		return "vscodium"
	default:
		return "vscode"
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
