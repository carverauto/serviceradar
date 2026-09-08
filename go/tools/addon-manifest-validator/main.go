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

// Command addon-manifest-validator validates native ServiceRadar add-on manifests
// (addon.yaml) against the published manifest JSON-Schema (issue 3425). It is the
// build/CI gate that fails closed before bundling on any manifest that is missing
// a required field or declares an unknown kind/delivery/supervision value.
//
// Usage:
//
//	addon-manifest-validator addons/sample-addon/addon.yaml [more.yaml ...]
//
// With no path arguments it validates every first-party add-on manifest discovered
// under addons/*/addon.yaml relative to the current working directory.
//
// Exit status:
//
//	0  all supplied manifests are valid
//	1  at least one manifest is invalid (fail closed)
//	2  usage / I/O error (no manifest found, unreadable file, ...)
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/carverauto/serviceradar/go/tools/addon-manifest-validator/internal/manifestschema"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr *os.File) int {
	fs := flag.NewFlagSet("addon-manifest-validator", flag.ContinueOnError)
	fs.SetOutput(stderr)
	glob := fs.String("glob", "addons/*/addon.yaml",
		"glob used to discover manifests when no explicit paths are given")
	quiet := fs.Bool("quiet", false, "only print failures")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	manifests := fs.Args()
	if len(manifests) == 0 {
		matched, err := filepath.Glob(*glob)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "error: invalid glob %q: %v\n", *glob, err)
			return 2
		}

		sort.Strings(matched)
		manifests = matched
	}

	if len(manifests) == 0 {
		_, _ = fmt.Fprintf(stderr, "error: no add-on manifests to validate (glob %q matched nothing)\n", *glob)
		return 2
	}

	failed := false

	for _, path := range manifests {
		data, err := os.ReadFile(path) //nolint:gosec // path is an operator-supplied manifest location.
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "error: reading %s: %v\n", path, err)
			return 2
		}

		res, err := manifestschema.ValidateYAML(data)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "FAIL %s: %v\n", path, err)
			failed = true
			continue
		}

		if !res.OK() {
			failed = true
			_, _ = fmt.Fprintf(stderr, "FAIL %s: %d schema violation(s)\n", path, len(res.Errors))
			for _, e := range res.Errors {
				_, _ = fmt.Fprintf(stderr, "  - %s\n", e.String())
			}
			continue
		}

		if !*quiet {
			_, _ = fmt.Fprintf(stdout, "OK   %s\n", path)
		}
	}

	if failed {
		_, _ = fmt.Fprintln(stderr, "addon-manifest-validator: one or more manifests are invalid; failing closed")
		return 1
	}

	return 0
}
