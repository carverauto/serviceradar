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

package scalibrinventory

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/addon"
	cpb "github.com/google/osv-scalibr/binary/proto/config_go_proto"
	scalibrfilesystem "github.com/google/osv-scalibr/extractor/filesystem"
	"github.com/google/osv-scalibr/extractor/filesystem/os/dpkg"
	scalibrfs "github.com/google/osv-scalibr/fs"
	"github.com/google/osv-scalibr/plugin"
	"github.com/google/osv-scalibr/result"
	"github.com/google/osv-scalibr/stats"
)

func TestResolveSkipDirectoriesUnionsBuiltinWhenOperatorEmpty(t *testing.T) {
	got := resolveSkipDirectories([]string{"/"}, nil)
	for _, want := range builtinSkipDirectories() {
		if !slices.Contains(got.Dirs, want) {
			t.Fatalf("empty operator skip list missing built-in %q: %v", want, got.Dirs)
		}
	}
	if len(got.Ignored) != 0 {
		t.Fatalf("empty operator list produced ignored paths: %v", got.Ignored)
	}
}

func TestResolveSkipDirectoriesKeepsOperatorExtras(t *testing.T) {
	got := resolveSkipDirectories([]string{"/"}, []string{"/mnt/build-cache"})
	if !slices.Contains(got.Dirs, "/mnt/build-cache") {
		t.Fatalf("operator extra missing from effective skip list: %v", got.Dirs)
	}
	for _, want := range builtinSkipDirectories() {
		if !slices.Contains(got.Dirs, want) {
			t.Fatalf("union dropped built-in %q: %v", want, got.Dirs)
		}
	}
}

func TestResolveSkipDirectoriesCannotDropBuiltin(t *testing.T) {
	got := resolveSkipDirectories([]string{"/"}, []string{"/var/cache"})
	if !slices.Contains(got.Dirs, "/proc") || !slices.Contains(got.Dirs, "/sys") ||
		!slices.Contains(got.Dirs, "/dev") || !slices.Contains(got.Dirs, "/run") {
		t.Fatalf("delivered skip list dropped built-in safety paths: %v", got.Dirs)
	}
	if !slices.Contains(got.Dirs, "/var/cache") {
		t.Fatalf("operator /var/cache missing: %v", got.Dirs)
	}
}

func TestResolveSkipDirectoriesIgnoresInvalidPaths(t *testing.T) {
	got := resolveSkipDirectories(
		[]string{"/opt"},
		[]string{"", "relative/cache", "/mnt/build-cache", "/opt/skip-me"},
	)
	if slices.Contains(got.Dirs, "relative/cache") || slices.Contains(got.Dirs, "/mnt/build-cache") {
		t.Fatalf("invalid operator paths were kept: dirs=%v ignored=%v", got.Dirs, got.Ignored)
	}
	if !slices.Contains(got.Dirs, "/opt/skip-me") {
		t.Fatalf("valid operator path under scan root missing: %v", got.Dirs)
	}
	if !slices.Contains(got.Ignored, "relative/cache") || !slices.Contains(got.Ignored, "/mnt/build-cache") {
		t.Fatalf("invalid operator paths were not recorded: %v", got.Ignored)
	}
	if slices.Contains(got.Dirs, "/proc") {
		t.Fatalf("built-in /proc is not under /opt but was kept: %v", got.Dirs)
	}
}

func TestResolveSkipDirectoriesSkipsNestedTreeDuringWalk(t *testing.T) {
	root := t.TempDir()
	cacheNested := filepath.Join(root, "cache", "nested")
	keepDir := filepath.Join(root, "keep")
	if err := os.MkdirAll(cacheNested, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(keepDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheNested, "secret"), []byte("nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(keepDir, "visible"), []byte("ok"), 0o600); err != nil {
		t.Fatal(err)
	}

	skip := resolveSkipDirectories([]string{root}, []string{filepath.Join(root, "cache")})
	extractor, err := dpkg.New(&cpb.PluginConfig{})
	if err != nil {
		t.Fatal(err)
	}
	visits := &visitCollector{}
	_, _, err = scalibrfilesystem.Run(t.Context(), &scalibrfilesystem.Config{
		Extractors: []scalibrfilesystem.Extractor{extractor},
		DirsToSkip: skip.Dirs,
		ScanRoots:  scalibrfs.RealFSScanRoots(root),
		Stats:      visits,
	})
	if err != nil {
		t.Fatal(err)
	}

	for _, path := range visits.paths {
		rel := path
		if filepath.IsAbs(path) {
			rel, _ = filepath.Rel(root, path)
		}
		rel = filepath.ToSlash(rel)
		if strings.HasPrefix(rel, "cache/") {
			t.Fatalf("walker visited skipped tree path %q", path)
		}
	}
	sawKeep := false
	for _, path := range visits.paths {
		rel := path
		if filepath.IsAbs(path) {
			rel, _ = filepath.Rel(root, path)
		}
		if filepath.ToSlash(rel) == "keep" || strings.HasPrefix(filepath.ToSlash(rel), "keep/") {
			sawKeep = true
			break
		}
	}
	if !sawKeep {
		t.Fatalf("walker did not visit unskipped keep/: %v", visits.paths)
	}
}

func TestScanActivityReportsEffectiveSkipUnion(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.ScanRoots = []string{"/"}
	cfg.DirsToSkip = []string{"/mnt/build-cache", "relative/cache"}
	runner := NewRunner(cfg)
	started := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	payload, _ := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
		StartTime: started,
		EndTime:   started.Add(time.Second),
		Status:    &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		PluginStatus: []*plugin.Status{{
			Name:   "os/dpkg",
			Status: &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		}},
	})
	activity, ok := payload.Metadata[metadataScannerActivityKey].(addon.ScannerScanActivity)
	if !ok {
		t.Fatalf("missing scanner activity: %#v", payload.Metadata)
	}
	dirs, _ := activity.Metadata["dirs_to_skip"].([]string)
	if !slices.Contains(dirs, "/mnt/build-cache") {
		t.Fatalf("effective dirs_to_skip missing operator path: %v", dirs)
	}
	if !slices.Contains(dirs, "/proc") {
		t.Fatalf("effective dirs_to_skip missing built-in /proc: %v", dirs)
	}
	ignored, _ := activity.Metadata["dirs_to_skip_ignored"].([]string)
	if !slices.Contains(ignored, "relative/cache") {
		t.Fatalf("ignored skip paths missing relative/cache: %v", ignored)
	}
}

type visitCollector struct {
	stats.NoopCollector
	paths []string
}

func (v *visitCollector) AfterInodeVisited(path string) {
	v.paths = append(v.paths, path)
}
