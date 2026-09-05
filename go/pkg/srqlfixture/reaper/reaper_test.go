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

package reaper

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

const protectedReason = "protected"

func TestTemplateGenerationNamespaceIsProtected(t *testing.T) {
	t.Parallel()

	generation := "sr_tpl_" + strings.Repeat("abcdef01", 6)
	for _, name := range []string{
		generation,
		generation + "_c12345",
		generation + "_1234567",             // PostgreSQL's 63-byte identifier limit.
		"sr_tpl_",                           // Missing digest.
		"sr_tpl_deadbeef",                   // Truncated digest.
		"sr_tpl_" + strings.Repeat("z", 48), // Non-hex digest.
		generation + "_unfinished_candidate",
		"sr_tpl_has space",
		`sr_tpl_has"quote`,
	} {
		t.Run(name, func(t *testing.T) {
			if !IsProtected(name) {
				t.Fatalf("reserved name %q is not protected", name)
			}
			if drop, reason := ShouldDrop(Database{Name: name, Age: 48 * time.Hour}, DefaultMaxAge); drop || reason != protectedReason {
				t.Fatalf("reserved name %q: drop=%v reason=%q", name, drop, reason)
			}
			if stmt, err := DropStatement(name); stmt != "" || !errors.Is(err, ErrProtected) {
				t.Fatalf("reserved name %q: statement=%q error=%v", name, stmt, err)
			}
		})
	}
}

func TestTemplateNamespaceDoesNotProtectUnrelatedScratchNames(t *testing.T) {
	t.Parallel()

	for _, name := range []string{"sr_tpl", "sr_tplx_deadbeef", "srXtpl_deadbeef", "scratch_sr_tpl_deadbeef", "sr_core_test_example"} {
		if IsProtected(name) {
			t.Fatalf("unrelated scratch name %q is protected", name)
		}
		if drop, reason := ShouldDrop(Database{Name: name, Age: 48 * time.Hour}, DefaultMaxAge); !drop {
			t.Fatalf("unrelated scratch name %q is not droppable: %s", name, reason)
		}
		if stmt, err := DropStatement(name); err != nil || stmt == "" {
			t.Fatalf("unrelated scratch name %q: statement=%q error=%v", name, stmt, err)
		}
	}
}

func TestScratchReaperSQLProtectsEntireTemplateNamespace(t *testing.T) {
	t.Parallel()

	body, _ := readScratchReaperSQL(t)
	// Require an unconditional prefix exclusion in the candidate WHERE clause.
	// A digest-shaped matcher would leave malformed reserved names droppable.
	guard := regexp.MustCompile(`(?m)^\s*AND d\.datname !~ '\^sr_tpl_'\s*$`)
	if !guard.Match(body) {
		t.Fatal("scratch reaper SQL must exclude the entire literal sr_tpl_ prefix")
	}
}

func TestShouldDropProtectsTheFixture(t *testing.T) {
	t.Parallel()

	for _, name := range ProtectedDatabases() {
		ok, reason := ShouldDrop(Database{Name: name, Age: 48 * time.Hour}, DefaultMaxAge)
		if ok {
			t.Fatalf("protected database %q was marked droppable (%s)", name, reason)
		}

		if reason != protectedReason {
			t.Fatalf("protected database %q: got reason %q", name, reason)
		}
	}
}

func TestShouldDropReapsStaleScratchNames(t *testing.T) {
	t.Parallel()

	stale := []string{
		"codex_mfreeman_123_456",
		"cc_clean_1786682771_26851",
		"serviceradar_bootstrap_test_8196",
		"sr_core_test_a1b2c3d4_async",
		"sr_baseline_ci_base_45308_1",
		"serviceradar_web_ng_test",
		"serviceradar",
	}

	for _, name := range stale {
		ok, reason := ShouldDrop(Database{Name: name, Age: 7 * time.Hour}, DefaultMaxAge)
		if !ok {
			t.Fatalf("expected to drop %q, got %s", name, reason)
		}
	}
}

func TestShouldDropSkipsLiveClientsAndYoungDatabases(t *testing.T) {
	t.Parallel()

	live, liveReason := ShouldDrop(Database{
		Name:          "codex_still_running",
		Age:           48 * time.Hour,
		HasLiveClient: true,
	}, DefaultMaxAge)
	if live {
		t.Fatal("must not drop a database with a live client")
	}

	if liveReason != "has a live client connection" {
		t.Fatalf("live client reason: %q", liveReason)
	}

	young, youngReason := ShouldDrop(Database{
		Name: "codex_fresh",
		Age:  time.Hour,
	}, DefaultMaxAge)
	if young {
		t.Fatal("must not drop a database younger than max age")
	}

	if youngReason != "younger than max age" {
		t.Fatalf("young reason: %q", youngReason)
	}

	if ok, _ := ShouldDrop(Database{Name: "codex_fresh", Age: time.Hour}, 0); ok {
		t.Fatal("non-positive max age must refuse")
	}
}

func TestSafeIdentRejectsCatalogOddities(t *testing.T) {
	t.Parallel()

	valid := []string{"postgres", "sr_core_test_a1", "Codex_User_1"}
	for _, name := range valid {
		if !SafeIdent(name) {
			t.Fatalf("expected %q to be safe", name)
		}
	}

	invalid := []string{
		"",
		"1leadingdigit",
		"has-hyphen",
		"has space",
		`has"quote`,
		"has;semicolon",
		strings.Repeat("a", 64),
	}
	for _, name := range invalid {
		if SafeIdent(name) {
			t.Fatalf("expected %q to be unsafe", name)
		}

		if _, err := DropStatement(name); err == nil {
			t.Fatalf("DropStatement(%q) should fail", name)
		}
	}
}

func TestDropStatementForcesAndQuotes(t *testing.T) {
	t.Parallel()

	got, err := DropStatement("codex_mfreeman_1")
	if err != nil {
		t.Fatal(err)
	}

	if got != `DROP DATABASE IF EXISTS "codex_mfreeman_1" WITH (FORCE)` {
		t.Fatalf("unexpected statement: %s", got)
	}

	if _, err := DropStatement("postgres"); err == nil {
		t.Fatal("must refuse to drop postgres")
	}
}

func TestScratchReaperSQLAgreesWithProtectedSet(t *testing.T) {
	t.Parallel()

	body, sqlPath := readScratchReaperSQL(t)

	sql := string(body)
	for _, name := range ProtectedDatabases() {
		if !strings.Contains(sql, "'"+name+"'") {
			t.Fatalf("%s does not mention protected database %q", sqlPath, name)
		}
	}

	if !strings.Contains(sql, "WITH (FORCE)") {
		t.Fatal("SQL must FORCE the drop so Timescale workers cannot pin leftover databases")
	}

	if !strings.Contains(sql, "TimescaleDB%") {
		t.Fatal("SQL must ignore Timescale background workers when detecting live clients")
	}

	yamlPath := strings.TrimSuffix(sqlPath, ".sql") + ".yaml"
	yamlBody, err := os.ReadFile(yamlPath)
	if err != nil {
		t.Fatalf("read %s: %v", yamlPath, err)
	}

	yamlText := string(yamlBody)
	if !strings.Contains(yamlText, "srql-fixture-scratch-reaper") {
		t.Fatalf("%s is not the scratch-reaper CronJob", yamlPath)
	}
	for _, name := range ProtectedDatabases() {
		if !strings.Contains(yamlText, "'"+name+"'") {
			t.Fatalf("%s ConfigMap SQL does not mention protected database %q", yamlPath, name)
		}
	}
}

func readScratchReaperSQL(t *testing.T) ([]byte, string) {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}

	candidates := []string{
		"k8s/srql-fixtures/scratch-reaper.sql",
		filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "k8s", "srql-fixtures", "scratch-reaper.sql"),
	}
	if srcdir := os.Getenv("TEST_SRCDIR"); srcdir != "" {
		workspace := os.Getenv("TEST_WORKSPACE")
		if workspace == "" {
			workspace = "serviceradar"
		}

		candidates = append([]string{filepath.Join(srcdir, workspace, "k8s", "srql-fixtures", "scratch-reaper.sql")}, candidates...)
	}

	var errs []string
	for _, path := range candidates {
		body, err := os.ReadFile(path)
		if err == nil {
			return body, path
		}

		errs = append(errs, fmt.Sprintf("%s: %v", path, err))
	}

	t.Fatalf("scratch-reaper.sql not found:\n%s", strings.Join(errs, "\n"))
	return nil, ""
}
