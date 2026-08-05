// Package bun scans Bun lockfiles.
//
// Two on-disk forms are recognized:
//
//   - bun.lock  — text JSONC. Best-effort parse: strip // and /* */ comments
//     and trailing commas, then json.Unmarshal. The schema we read is
//     {"packages":{"<name>":["<name>@<version>", ...]}}.
//   - bun.lockb — Bun's binary v0 lockfile format. We do NOT parse binary
//     contents in v0.1. Presence is logged as a diagnostic so an operator
//     knows Bun was used here, but no records are emitted from it.
package bun

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/model"
	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/normalize"
)

const Ecosystem = model.EcosystemNPM

type Scanner struct {
	MaxFileSize int64
	Emit        func(model.Record)
	Diag        func(level, path, msg string)
}

func IsTextLockfile(base string) bool   { return base == "bun.lock" }
func IsBinaryLockfile(base string) bool { return base == "bun.lockb" }

// NoteBinaryLockfile records the existence of a binary bun.lockb without
// parsing it. v0.1 does not implement the binary format.
func (s *Scanner) NoteBinaryLockfile(path string) {
	if s.Diag != nil {
		s.Diag("info", path, "bun.lockb detected; binary format not parsed in v0.1")
	}
}

func (s *Scanner) ScanTextLockfile(path string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	stripped, stripErr := stripJSONC(data)
	if stripErr != nil && s.Diag != nil {
		s.Diag("warn", path, stripErr.Error())
	}
	projectPath := filepath.Dir(path)

	var lf struct {
		LockfileVersion int                        `json:"lockfileVersion"`
		Packages        map[string]json.RawMessage `json:"packages"`
	}
	if err := json.Unmarshal(stripped, &lf); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	directs := loadDirectDeps(filepath.Join(projectPath, "package.json"), s.MaxFileSize, s.Diag)
	keys := make([]string, 0, len(lf.Packages))
	for k := range lf.Packages {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		raw := lf.Packages[key]
		name, version, derr := decodeBunEntry(key, raw)
		if derr != nil && s.Diag != nil {
			s.Diag("warn", path, derr.Error())
		}
		if name == "" || version == "" {
			continue
		}
		r := base
		r.Ecosystem = Ecosystem
		r.PackageName = name
		r.NormalizedName = normalize.NPM(name)
		r.Version = version
		r.ProjectPath = projectPath
		r.PackageManager = "bun"
		r.SourceType = "bun-lockfile"
		r.SourceFile = path
		if directs != nil {
			d := directs[name]
			r.DirectDependency = &d
		}
		r.Confidence = "high"
		s.Emit(r)
	}
	return nil
}

// loadDirectDeps reads a package.json sibling to bun.lock and returns a set
// of package names from any top-level dependency section. Returns nil if the
// file is missing, oversized, or unparseable so callers can leave
// DirectDependency unset rather than guessing.
//
// A non-nil diag is invoked for read or parse failures of a package.json
// that exists. Missing files are silent (no diag): the common case is a
// lockfile checked into a repo without its sibling package.json.
func loadDirectDeps(path string, maxSize int64, diag func(level, path, msg string)) map[string]bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil
	}
	if maxSize > 0 && info.Size() > maxSize {
		if diag != nil {
			diag("warn", path, "skipping direct-dependency resolution: package.json exceeds max file size")
		}
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if diag != nil {
			diag("warn", path, "read package.json for direct-dependency resolution: "+err.Error())
		}
		return nil
	}
	var pj struct {
		Dependencies         map[string]string `json:"dependencies"`
		DevDependencies      map[string]string `json:"devDependencies"`
		OptionalDependencies map[string]string `json:"optionalDependencies"`
		PeerDependencies     map[string]string `json:"peerDependencies"`
	}
	if err := json.Unmarshal(data, &pj); err != nil {
		if diag != nil {
			diag("warn", path, "parse package.json for direct-dependency resolution: "+err.Error())
		}
		return nil
	}
	out := map[string]bool{}
	for n := range pj.Dependencies {
		out[n] = true
	}
	for n := range pj.DevDependencies {
		out[n] = true
	}
	for n := range pj.OptionalDependencies {
		out[n] = true
	}
	for n := range pj.PeerDependencies {
		out[n] = true
	}
	return out
}

// decodeBunEntry handles the multiple shapes Bun's lockfile uses for a value.
// The most common is an array whose first element is "<name>@<version>".
// Object form {"version":"..."} is also accepted.
//
// Returns a non-nil error when an array-form entry is recognized but its
// first element does not yield a parseable version descriptor. Callers
// should surface this as a diagnostic so silent record loss is visible.
func decodeBunEntry(key string, raw json.RawMessage) (name, version string, err error) {
	name = key
	// Try array form first.
	var arr []json.RawMessage
	if uerr := json.Unmarshal(raw, &arr); uerr == nil && len(arr) > 0 {
		var first string
		if jerr := json.Unmarshal(arr[0], &first); jerr == nil {
			n, v := splitAtVersion(first)
			if n != "" {
				name = n
			}
			version = v
		}
		if version == "" {
			err = fmt.Errorf("bun.lock entry %q has unparseable version descriptor", key)
		}
		return
	}
	// Object form.
	var obj map[string]json.RawMessage
	if uerr := json.Unmarshal(raw, &obj); uerr == nil {
		if v, ok := obj["version"]; ok {
			_ = json.Unmarshal(v, &version)
		}
	}
	return
}

// splitAtVersion takes "name@version" or "@scope/name@version" and returns
// (name, version).
func splitAtVersion(s string) (name, version string) {
	if s == "" {
		return "", ""
	}
	if strings.HasPrefix(s, "@") {
		slash := strings.IndexByte(s, '/')
		if slash < 0 {
			return s, ""
		}
		rest := s[slash:]
		at := strings.IndexByte(rest, '@')
		if at < 0 {
			return s, ""
		}
		return s[:slash+at], s[slash+at+1:]
	}
	at := strings.IndexByte(s, '@')
	if at <= 0 {
		return s, ""
	}
	return s[:at], s[at+1:]
}

// stripJSONC removes // line comments, /* block comments */, and trailing
// commas from JSONC input. It is intentionally simple and only respects
// string boundaries so commas/comments inside strings are preserved.
//
// Returns an error when a `/*` block comment reaches EOF without a
// closing `*/`. In that case the original bytes are returned unchanged
// so the JSON parser produces its own diagnostic instead of silently
// consuming the remainder of the file.
func stripJSONC(in []byte) ([]byte, error) {
	out := make([]byte, 0, len(in))
	i := 0
	inStr := false
	for i < len(in) {
		c := in[i]
		if inStr {
			out = append(out, c)
			if c == '\\' && i+1 < len(in) {
				out = append(out, in[i+1])
				i += 2
				continue
			}
			if c == '"' {
				inStr = false
			}
			i++
			continue
		}
		if c == '"' {
			inStr = true
			out = append(out, c)
			i++
			continue
		}
		if c == '/' && i+1 < len(in) {
			if in[i+1] == '/' {
				// Skip to end of line.
				for i < len(in) && in[i] != '\n' {
					i++
				}
				continue
			}
			if in[i+1] == '*' {
				i += 2
				closed := false
				for i+1 < len(in) {
					if in[i] == '*' && in[i+1] == '/' {
						closed = true
						break
					}
					i++
				}
				if !closed {
					return in, errors.New("unterminated block comment in bun.lock")
				}
				i += 2
				continue
			}
		}
		out = append(out, c)
		i++
	}
	// Trailing-comma pass: ",]" -> "]" and ",}" -> "}".
	// String-aware: never edit bytes inside a JSON string.
	cleaned := make([]byte, 0, len(out))
	inStr2 := false
	for j := 0; j < len(out); j++ {
		c := out[j]
		if inStr2 {
			cleaned = append(cleaned, c)
			if c == '\\' && j+1 < len(out) {
				cleaned = append(cleaned, out[j+1])
				j++
				continue
			}
			if c == '"' {
				inStr2 = false
			}
			continue
		}
		if c == '"' {
			inStr2 = true
			cleaned = append(cleaned, c)
			continue
		}
		if c == ',' {
			k := j + 1
			for k < len(out) && (out[k] == ' ' || out[k] == '\n' || out[k] == '\r' || out[k] == '\t') {
				k++
			}
			if k < len(out) && (out[k] == '}' || out[k] == ']') {
				continue
			}
		}
		cleaned = append(cleaned, c)
	}
	return cleaned, nil
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
