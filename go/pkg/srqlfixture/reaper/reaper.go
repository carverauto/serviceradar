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

// Package reaper drops leftover scratch databases on the shared srql-fixtures CNPG cluster.
//
// CI only sweeps `sr_core_test_*` at the start of a guarded run, so workstation clones
// (codex_*, cc_*, serviceradar_bootstrap_test_*, …) accumulate until Timescale background
// workers exhaust the instance. Anything not covered by IsProtected is fair game: this
// cluster is a disposable fixture, not a place to keep long-lived databases.
package reaper

import (
	"fmt"
	"strings"
	"time"
	"unicode"
)

const (
	// DefaultMaxAge is long enough that a live integration run still holding
	// connections is left alone, and short enough that a cancelled job cannot
	// starve Timescale workers for days.
	DefaultMaxAge = 6 * time.Hour
)

// ProtectedDatabases lists the exact names that are never dropped, regardless of
// age. IsProtected also protects reserved namespaces. Keep these exclusions in
// sync with k8s/srql-fixtures/scratch-reaper.sql and rust/integration-db.
func ProtectedDatabases() []string {
	return []string{
		"postgres",
		"template0",
		"template1",
		"srql_fixture",
		"sr_core_template",
	}
}

// Database is one candidate the reaper considers.
type Database struct {
	Name          string
	Age           time.Duration
	HasLiveClient bool
}

// ShouldDrop reports whether a database may be dropped.
func ShouldDrop(db Database, maxAge time.Duration) (bool, string) {
	if maxAge <= 0 {
		return false, "max age must be greater than zero"
	}

	if IsProtected(db.Name) {
		return false, "protected"
	}

	if !SafeIdent(db.Name) {
		return false, "name is not a safe identifier"
	}

	if db.HasLiveClient {
		return false, "has a live client connection"
	}

	if db.Age < maxAge {
		return false, "younger than max age"
	}

	return true, "stale unprotected"
}

// IsProtected reports whether name is an exact protected name or belongs to the
// reserved template generation namespace. Protect even malformed reserved names:
// only dedicated registry cleanup may manage generations and private candidates.
func IsProtected(name string) bool {
	if strings.HasPrefix(name, "sr_tpl_") {
		return true
	}

	for _, protected := range ProtectedDatabases() {
		if name == protected {
			return true
		}
	}

	return false
}

// SafeIdent reports whether name is a conservative SQL identifier.
// The reaper only ever quotes names that match this, so a catalog row with
// whitespace or punctuation cannot be turned into a statement.
func SafeIdent(name string) bool {
	if name == "" || len(name) > 63 {
		return false
	}

	for i, r := range name {
		if r == '_' {
			continue
		}

		if unicode.IsLetter(r) {
			continue
		}

		if unicode.IsDigit(r) && i > 0 {
			continue
		}

		return false
	}

	return true
}

// QuoteIdent quotes a PostgreSQL identifier by doubling embedded quotes.
func QuoteIdent(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}

// DropStatement returns the SQL that drops one scratch database, forcing off
// Timescale background workers that would otherwise keep the DROP waiting.
func DropStatement(name string) (string, error) {
	if IsProtected(name) {
		return "", fmt.Errorf("%w: %s", ErrProtected, name)
	}

	if !SafeIdent(name) {
		return "", fmt.Errorf("%w: %s", ErrUnsafeIdent, name)
	}

	return "DROP DATABASE IF EXISTS " + QuoteIdent(name) + " WITH (FORCE)", nil
}
