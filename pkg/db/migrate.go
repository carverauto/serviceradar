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

package db

import (
	"context"
	"embed"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2"

	"github.com/carverauto/serviceradar/pkg/logger"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

const (
	migrationsTable        = "schema_migrations"
	migrationRetryAttempts = 5
	migrationRetryDelay    = 2 * time.Second
)

// RunMigrations checks for and applies all pending database migrations.
func RunMigrations(ctx context.Context, conn proton.Conn, log logger.Logger) error {
	log.Info().Msg("Running database migrations")

	// 1. Ensure the migrations tracking table exists.
	if err := createMigrationsTable(ctx, conn); err != nil {
		return fmt.Errorf("failed to create migrations table: %w", err)
	}

	// 2. Get the list of already applied migrations.
	appliedMigrations, err := getAppliedMigrations(ctx, conn)
	if err != nil {
		return fmt.Errorf("failed to get applied migrations: %w", err)
	}

	log.Info().Int("applied_count", len(appliedMigrations)).Msg("Found applied migrations")

	// 3. Get all available migrations from the filesystem.
	availableMigrations, err := getAvailableMigrations()
	if err != nil {
		return fmt.Errorf("failed to get available migrations: %w", err)
	}

	log.Info().Int("available_count", len(availableMigrations)).Msg("Found available migrations")

	// 4. Apply any migrations that have not yet been run.
	for _, migrationFile := range availableMigrations {
		version := extractVersion(migrationFile)
		if _, ok := appliedMigrations[version]; ok {
			continue // Skip already applied migration
		}

		log.Info().Str("migration_file", migrationFile).Msg("Applying migration")

		// Read the migration content
		content, err := migrationsFS.ReadFile("migrations/" + migrationFile)
		if err != nil {
			return fmt.Errorf("failed to read migration file %s: %w", migrationFile, err)
		}

		// Split the migration into individual statements and execute them
		if err := executeMultiStatementMigration(ctx, conn, string(content), migrationFile, log); err != nil {
			return fmt.Errorf("failed to apply migration %s: %w", migrationFile, err)
		}

		// Record the migration version
		if err := recordMigration(ctx, conn, version); err != nil {
			return fmt.Errorf("failed to record migration %s: %w", migrationFile, err)
		}

		log.Info().Str("migration_file", migrationFile).Msg("Successfully applied and recorded migration")
	}

	log.Info().Msg("Database migrations finished")

	return nil
}

// executeMultiStatementMigration splits a migration file into individual SQL statements
// and executes them one by one, handling both single and multi-statement migrations.
func executeMultiStatementMigration(ctx context.Context, conn proton.Conn, content, filename string, log logger.Logger) error {
	// Split the content into individual statements
	statements := splitSQLStatements(content)

	for i, stmt := range statements {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}

		log.Debug().Int("statement_num", i+1).Int("total_statements", len(statements)).Str("filename", filename).Msg("Executing statement")

		// Check if this is a long-running INSERT...SELECT statement
		if strings.Contains(strings.ToUpper(stmt), "INSERT INTO") &&
			strings.Contains(strings.ToUpper(stmt), "SELECT") &&
			strings.Contains(stmt, "timeseries_metrics") {
			// Use extended timeout for data migration
			log.Info().Msg("Detected data migration statement, using extended timeout")

			// First, set max_execution_time
			if err := conn.Exec(ctx, "SET max_execution_time = 3600"); err != nil {
				log.Warn().Err(err).Msg("Couldn't set max_execution_time")
			}

			// Execute with extended context timeout
			migrationCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)

			err := execStatementWithRetry(migrationCtx, conn, stmt, log)
			// Call cancel immediately after the operation completes
			cancel()

			if err != nil {
				return fmt.Errorf("failed to execute statement %d: %w\nStatement: %s", i+1, err, stmt)
			}

			// Reset max_execution_time
			if err := conn.Exec(ctx, "SET max_execution_time = 60"); err != nil {
				log.Warn().Err(err).Msg("Couldn't reset max_execution_time")
			}
		} else {
			// Normal execution for other statements
			if err := execStatementWithRetry(ctx, conn, stmt, log); err != nil {
				return fmt.Errorf("failed to execute statement %d: %w\nStatement: %s", i+1, err, stmt)
			}
		}
	}

	return nil
}

func execStatementWithRetry(ctx context.Context, conn proton.Conn, stmt string, log logger.Logger) error {
	for attempt := 1; attempt <= migrationRetryAttempts; attempt++ {
		err := conn.Exec(ctx, stmt)
		if err == nil {
			return nil
		}

		if !isRetryableMigrationError(err) || attempt == migrationRetryAttempts {
			return err
		}

		log.Warn().
			Int("attempt", attempt).
			Int("max_attempts", migrationRetryAttempts).
			Err(err).
			Msg("migration statement conflicted with concurrent Proton change; retrying")

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(migrationRetryDelay):
		}
	}

	return nil
}

func isRetryableMigrationError(err error) bool {
	if err == nil {
		return false
	}

	msg := err.Error()
	return strings.Contains(msg, "version changed")
}

// splitSQLStatements splits SQL content into individual statements.
// It handles comments and multi-line SETTINGS blocks properly.
func splitSQLStatements(content string) []string {
	var statements []string

	var currentStatement strings.Builder

	lines := strings.Split(content, "\n")

	parser := &sqlStatementParser{
		inSettingsBlock:  false,
		parenthesesDepth: 0,
	}

	for _, line := range lines {
		if shouldSkipLine(line) {
			appendNewlineIfNeeded(&currentStatement)
			continue
		}

		appendLineToStatement(&currentStatement, line)
		parser.updateState(line)

		if parser.shouldSplitStatement(line) {
			if stmt := extractStatement(&currentStatement); stmt != "" {
				statements = append(statements, stmt)
			}

			currentStatement.Reset()
			parser.reset()
		}
	}

	// Add any remaining statement
	if stmt := extractStatement(&currentStatement); stmt != "" {
		statements = append(statements, stmt)
	}

	return statements
}

// sqlStatementParser tracks the state needed for parsing SQL statements
type sqlStatementParser struct {
	inSettingsBlock  bool
	parenthesesDepth int
}

// shouldSkipLine checks if a line should be skipped (comments and empty lines)
func shouldSkipLine(line string) bool {
	trimmedLine := strings.TrimSpace(line)
	return strings.HasPrefix(trimmedLine, "--") || trimmedLine == ""
}

// appendNewlineIfNeeded adds a newline to the statement if it's not empty
func appendNewlineIfNeeded(stmt *strings.Builder) {
	if stmt.Len() > 0 {
		stmt.WriteString("\n")
	}
}

// appendLineToStatement adds a line to the current statement
func appendLineToStatement(stmt *strings.Builder, line string) {
	appendNewlineIfNeeded(stmt)
	stmt.WriteString(line)
}

// updateState updates the parser state based on the current line
func (p *sqlStatementParser) updateState(line string) {
	trimmedLine := strings.TrimSpace(line)
	upperLine := strings.ToUpper(trimmedLine)

	if strings.Contains(upperLine, "SETTINGS") {
		p.inSettingsBlock = true
	}

	// Count parentheses
	for _, char := range line {
		switch char {
		case '(':
			p.parenthesesDepth++
		case ')':
			p.parenthesesDepth--
		}
	}
}

// shouldSplitStatement determines if we should split the statement at this line
func (p *sqlStatementParser) shouldSplitStatement(line string) bool {
	trimmedLine := strings.TrimSpace(line)

	if !strings.HasSuffix(trimmedLine, ";") {
		return false
	}

	// If we're in a SETTINGS block, check if this semicolon ends it
	if p.inSettingsBlock && p.parenthesesDepth == 0 {
		p.inSettingsBlock = false
	}

	// Split only if we're not in a SETTINGS block
	return !p.inSettingsBlock
}

// reset resets the parser state after splitting a statement
func (p *sqlStatementParser) reset() {
	p.parenthesesDepth = 0
}

// extractStatement extracts and cleans a statement from the builder
func extractStatement(stmt *strings.Builder) string {
	if stmt.Len() == 0 {
		return ""
	}

	result := strings.TrimSpace(stmt.String())
	result = strings.TrimSuffix(result, ";")

	return result
}

func createMigrationsTable(ctx context.Context, conn proton.Conn) error {
	return conn.Exec(ctx, fmt.Sprintf(`
		CREATE STREAM IF NOT EXISTS %s (
			version string
		)
	`, migrationsTable))
}

func getAppliedMigrations(ctx context.Context, conn proton.Conn) (map[string]struct{}, error) {
	rows, err := conn.Query(ctx, fmt.Sprintf("SELECT version FROM table(%s)", migrationsTable))
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = rows.Close()
	}()

	applied := make(map[string]struct{})

	for rows.Next() {
		var version string

		if err := rows.Scan(&version); err != nil {
			return nil, err
		}

		applied[version] = struct{}{}
	}

	return applied, nil
}

func getAvailableMigrations() ([]string, error) {
	files, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return nil, err
	}

	var available []string

	for _, file := range files {
		if !file.IsDir() && strings.HasSuffix(file.Name(), ".up.sql") {
			available = append(available, file.Name())
		}
	}

	// Sort migrations by version (filename)
	sort.Strings(available)

	return available, nil
}

func recordMigration(ctx context.Context, conn proton.Conn, version string) error {
	batch, err := conn.PrepareBatch(ctx, fmt.Sprintf("INSERT INTO %s (version)", migrationsTable))
	if err != nil {
		return err
	}

	if err := batch.Append(version); err != nil {
		return err
	}

	return batch.Send()
}

func extractVersion(filename string) string {
	return strings.Split(filename, "_")[0]
}
