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
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

func DiscoverRoots(cfg Config) ([]RootCandidate, []SkippedRoot) {
	seen := make(map[string]struct{})
	excluded := excludeSet(cfg.ExcludeRoots)
	var roots []RootCandidate
	var skipped []SkippedRoot

	add := func(path, source string) {
		clean, ok := cleanRoot(path)
		if !ok {
			skipped = append(skipped, SkippedRoot{Path: path, Reason: "invalid_path"})
			return
		}
		if _, skip := excluded[clean]; skip {
			skipped = append(skipped, SkippedRoot{Path: clean, Reason: "excluded"})
			return
		}
		if _, ok := seen[clean]; ok {
			return
		}
		seen[clean] = struct{}{}
		roots = append(roots, RootCandidate{Path: clean, Source: source})
	}

	if cfg.IncludeRoot {
		add("/root", "root")
	}

	if cfg.IncludeHomeRoots {
		homeRoots, homeSkipped := discoverHomeRoots(cfg.PasswdPath)
		skipped = append(skipped, homeSkipped...)
		for _, root := range homeRoots {
			add(root.Path, root.Source)
		}
	}

	for _, root := range cfg.ExplicitRoots {
		add(root, "explicit")
	}

	return roots, skipped
}

func discoverHomeRoots(passwdPath string) ([]RootCandidate, []SkippedRoot) {
	file, err := os.Open(passwdPath)
	if err != nil {
		return nil, []SkippedRoot{{Path: passwdPath, Reason: "passwd_unreadable"}}
	}
	defer func() { _ = file.Close() }()

	var roots []RootCandidate
	var skipped []SkippedRoot
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ":")
		if len(fields) < 6 {
			continue
		}

		username := strings.TrimSpace(fields[0])
		home := strings.TrimSpace(fields[5])
		clean, ok := cleanRoot(home)
		if !ok || clean == "/" {
			continue
		}
		if _, err := os.Stat(clean); err != nil {
			skipped = append(skipped, SkippedRoot{Path: clean, Reason: "home_unavailable:" + username})
			continue
		}
		roots = append(roots, RootCandidate{Path: clean, Source: "passwd:" + username})
	}

	if err := scanner.Err(); err != nil {
		skipped = append(skipped, SkippedRoot{Path: passwdPath, Reason: "passwd_read_failed"})
	}

	return roots, skipped
}

func cleanRoot(path string) (string, bool) {
	path = strings.TrimSpace(path)
	if path == "" || !filepath.IsAbs(path) {
		return "", false
	}

	return filepath.Clean(path), true
}

func excludeSet(paths []string) map[string]struct{} {
	out := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		if clean, ok := cleanRoot(path); ok {
			out[clean] = struct{}{}
		}
	}

	return out
}
