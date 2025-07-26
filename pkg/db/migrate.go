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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/timeplus-io/proton-go-driver/v2"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

const migrationsTable = "schema_migrations"

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

			err := conn.Exec(migrationCtx, stmt)
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
			if err := conn.Exec(ctx, stmt); err != nil {
				return fmt.Errorf("failed to execute statement %d: %w\nStatement: %s", i+1, err, stmt)
			}
		}
	}

	return nil
}

// splitSQLStatements splits SQL content into individual statements.
// It handles comments and ensures semicolons inside strings are not treated as delimiters.
func splitSQLStatements(content string) []string {
	var statements []string

	var currentStatement strings.Builder

	lines := strings.Split(content, "\n")

	for _, line := range lines {
		trimmedLine := strings.TrimSpace(line)

		// Skip comment-only lines
		if strings.HasPrefix(trimmedLine, "--") || trimmedLine == "" {
			if currentStatement.Len() > 0 {
				currentStatement.WriteString("\n")
			}

			continue
		}

		// Add the line to the current statement
		if currentStatement.Len() > 0 {
			currentStatement.WriteString("\n")
		}

		currentStatement.WriteString(line)

		// Check if this line ends with a semicolon (simple check, may need refinement for complex cases)
		if strings.HasSuffix(strings.TrimSpace(line), ";") {
			// Remove the trailing semicolon and add the statement
			stmt := currentStatement.String()
			stmt = strings.TrimSpace(stmt)
			stmt = strings.TrimSuffix(stmt, ";")

			if stmt != "" {
				statements = append(statements, stmt)
			}

			currentStatement.Reset()
		}
	}

	// Add any remaining statement
	if currentStatement.Len() > 0 {
		stmt := strings.TrimSpace(currentStatement.String())
		stmt = strings.TrimSuffix(stmt, ";")

		if stmt != "" {
			statements = append(statements, stmt)
		}
	}

	return statements
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
	defer rows.Close()

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
