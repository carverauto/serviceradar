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

// Command gostripcomments reads Go source on stdin and writes it back canonically
// formatted with ALL comments removed, using the Go parser/printer (NOT a lexical
// strip). It is used by verify-proto-bazel-parity so the Bazel-vs-Make comparison
// is comment-insensitive but Go-aware: string literals (e.g. a protobuf rawDesc)
// are preserved exactly, so a real descriptor/error-text change is never masked.
package main

import (
	"go/parser"
	"go/printer"
	"go/token"
	"io"
	"os"
)

func main() {
	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		_, _ = os.Stderr.WriteString("read: " + err.Error() + "\n")
		os.Exit(1)
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "in.go", src, parser.SkipObjectResolution)
	if err != nil {
		_, _ = os.Stderr.WriteString("parse: " + err.Error() + "\n")
		os.Exit(1)
	}
	f.Comments = nil // drop every comment; string literals are untouched
	// RawFormat disables tabwriter column alignment, so struct-field alignment
	// differences (driven by removed doc comments) do not matter; blank lines left
	// where comments were are dropped by the Makefile's `grep -v`.
	cfg := printer.Config{Mode: printer.RawFormat, Tabwidth: 1}
	if err := cfg.Fprint(os.Stdout, fset, f); err != nil {
		_, _ = os.Stderr.WriteString("print: " + err.Error() + "\n")
		os.Exit(1)
	}
}
