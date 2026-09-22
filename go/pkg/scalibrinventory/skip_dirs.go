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
	"path/filepath"
	"sort"
	"strings"
)

// builtinSkipDirectories is the safety set always unioned into the ScaLibr walk.
// Operators can add paths via dirs_to_skip; they cannot remove these.
func builtinSkipDirectories() []string {
	return []string{
		"/proc",
		"/sys",
		"/dev",
		"/run",
		"/tmp",
		"/var/tmp",
		"/var/cache",
		"/var/lib/docker",
		"/var/lib/containerd",
		"/var/lib/rancher",
		"/var/lib/kubelet",
		"/var/lib/containers",
		"/var/lib/buildah",
		"/var/lib/buildbuddy",
		"/var/lib/serviceradar/endpoint-inventory",
	}
}

type skipResolution struct {
	Dirs    []string
	Ignored []string
}

func resolveSkipDirectories(scanRoots []string, operator []string) skipResolution {
	roots := cleanScanRoots(scanRoots)
	effective := make(map[string]struct{})
	ignored := make([]string, 0)

	for _, path := range builtinSkipDirectories() {
		if skipPathUnderScanRoots(path, roots) {
			effective[path] = struct{}{}
		}
	}

	for _, raw := range operator {
		path := filepath.Clean(strings.TrimSpace(raw))
		if path == "" || path == "." {
			continue
		}
		if !filepath.IsAbs(path) || !skipPathUnderScanRoots(path, roots) {
			ignored = append(ignored, strings.TrimSpace(raw))
			continue
		}
		effective[path] = struct{}{}
	}

	dirs := make([]string, 0, len(effective))
	for path := range effective {
		dirs = append(dirs, path)
	}
	sort.Strings(dirs)
	sort.Strings(ignored)

	return skipResolution{Dirs: dirs, Ignored: uniqueStrings(ignored)}
}

func cleanScanRoots(scanRoots []string) []string {
	roots := make([]string, 0, len(scanRoots))
	for _, raw := range scanRoots {
		root := filepath.Clean(strings.TrimSpace(raw))
		if root == "" || root == "." {
			continue
		}
		roots = append(roots, root)
	}
	return roots
}

func skipPathUnderScanRoots(path string, roots []string) bool {
	if !filepath.IsAbs(path) {
		return false
	}
	for _, root := range roots {
		if root == string(filepath.Separator) {
			return true
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			continue
		}
		if rel == "." {
			return true
		}
		if rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func uniqueStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}
