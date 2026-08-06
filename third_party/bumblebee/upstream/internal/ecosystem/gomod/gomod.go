// Package gomod scans Go module artifacts: go.sum and go.mod.
//
// go.sum is the most reliable inventory source because it lists exactly the
// modules at the versions Go fetched, with their content hashes. go.mod
// requirements are also recorded (lower-confidence: they may not all end up
// in the final build set).
//
// No `go` commands are executed. Dispatch is filename-based, so any
// `go.sum` / `go.mod` reachable from a configured root is parsed —
// including files inside the per-user module cache (`~/go/pkg/mod`)
// when `~/go` is a baseline root. The cache's source-file subtrees
// are not walked for anything beyond those two filenames.
package gomod

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/model"
)

const Ecosystem = model.EcosystemGo

type Scanner struct {
	MaxFileSize int64
	Emit        func(model.Record)
	Diag        func(level, path, msg string)
}

func IsGoSum(base string) bool { return base == "go.sum" }
func IsGoMod(base string) bool { return base == "go.mod" }

func (s *Scanner) ScanGoSum(path string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	projectPath := filepath.Dir(path)
	seen := make(map[string]struct{})

	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 3 {
			continue
		}
		module := fields[0]
		version := fields[1]
		// Skip "module/go.mod" pseudo-entries; the module entry is enough.
		if strings.HasSuffix(version, "/go.mod") {
			continue
		}
		key := module + "\x00" + version
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}

		r := base
		r.Ecosystem = Ecosystem
		r.PackageName = module
		r.NormalizedName = strings.ToLower(module)
		r.Version = version
		r.ProjectPath = projectPath
		r.PackageManager = "go"
		r.SourceType = "go-sum"
		r.SourceFile = path
		r.Confidence = "high"
		s.Emit(r)
	}
	return nil
}

func (s *Scanner) ScanGoMod(path string, base model.Record) error {
	data, err := s.readBounded(path)
	if err != nil {
		return err
	}
	projectPath := filepath.Dir(path)
	reqs := parseGoModRequires(data)
	for _, r := range reqs {
		if r.module == "" || r.version == "" {
			continue
		}
		rec := base
		rec.Ecosystem = Ecosystem
		rec.PackageName = r.module
		rec.NormalizedName = strings.ToLower(r.module)
		rec.Version = r.version
		rec.ProjectPath = projectPath
		rec.PackageManager = "go"
		rec.SourceType = "go-mod"
		rec.SourceFile = path
		if r.indirect {
			rec.InstallScope = "indirect"
			direct := false
			rec.DirectDependency = &direct
		} else {
			direct := true
			rec.DirectDependency = &direct
		}
		rec.Confidence = "medium"
		s.Emit(rec)
	}
	return nil
}

type goModRequire struct {
	module   string
	version  string
	indirect bool
}

func parseGoModRequires(data []byte) []goModRequire {
	var out []goModRequire
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	inBlock := false
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		comment := ""
		if i := strings.Index(line, "//"); i >= 0 {
			comment = strings.TrimSpace(line[i+2:])
			line = strings.TrimSpace(line[:i])
		}
		if !inBlock {
			if line == "require (" {
				inBlock = true
				continue
			}
			if strings.HasPrefix(line, "require ") {
				rest := strings.TrimSpace(strings.TrimPrefix(line, "require"))
				if r, ok := parseGoModRequireLine(rest, comment); ok {
					out = append(out, r)
				}
				continue
			}
			continue
		}
		if line == ")" {
			inBlock = false
			continue
		}
		if r, ok := parseGoModRequireLine(line, comment); ok {
			out = append(out, r)
		}
	}
	return out
}

func parseGoModRequireLine(line, comment string) (goModRequire, bool) {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return goModRequire{}, false
	}
	return goModRequire{
		module:   fields[0],
		version:  fields[1],
		indirect: strings.Contains(comment, "indirect"),
	}, true
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
