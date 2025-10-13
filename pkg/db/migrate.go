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
	"strings"

	"github.com/timeplus-io/proton-go-driver/v2"

	"github.com/carverauto/serviceradar/pkg/logger"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

const schemaFile = "migrations/schema.sql"

// RunMigrations applies the consolidated database schema when no tables exist yet.
func RunMigrations(ctx context.Context, conn proton.Conn, log logger.Logger) error {
	log.Info().Msg("Ensuring database schema is applied")

	applied, err := schemaAlreadyApplied(ctx, conn)
	if err != nil {
		return fmt.Errorf("failed to inspect existing schema: %w", err)
	}

	if applied {
		log.Info().Msg("Schema already present; skipping apply")
		return nil
	}

	content, err := migrationsFS.ReadFile(schemaFile)
	if err != nil {
		return fmt.Errorf("failed to read schema file: %w", err)
	}

	statements := splitSQLStatements(string(content))
	log.Info().Int("statement_count", len(statements)).Msg("Applying database schema")

	for i, stmt := range statements {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}

		log.Debug().
			Int("statement_num", i+1).
			Int("total_statements", len(statements)).
			Msg("Executing schema statement")

		if err := conn.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("failed to execute schema statement %d: %w\nStatement: %s", i+1, err, stmt)
		}
	}

	log.Info().Msg("Database schema applied successfully")
	return nil
}

func schemaAlreadyApplied(ctx context.Context, conn proton.Conn) (bool, error) {
	rows, err := conn.Query(ctx, "SELECT count() FROM system.tables WHERE database = current_database() AND name = 'device_updates'")
	if err != nil {
		return false, err
	}
	defer func() {
		_ = rows.Close()
	}()

	var count uint64
	if rows.Next() {
		if err := rows.Scan(&count); err != nil {
			return false, err
		}
	}

	return count > 0, nil
}

// splitSQLStatements splits SQL content into individual statements.
// It handles comments and multi-line SETTINGS blocks properly.
func splitSQLStatements(content string) []string {
	var statements []string
	var currentStatement strings.Builder

	lines := strings.Split(content, "\n")
	parser := &sqlStatementParser{}

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

	if stmt := extractStatement(&currentStatement); stmt != "" {
		statements = append(statements, stmt)
	}

	return statements
}

type sqlStatementParser struct {
	inSettingsBlock  bool
	parenthesesDepth int
}

func shouldSkipLine(line string) bool {
	trimmedLine := strings.TrimSpace(line)
	return trimmedLine == "" || strings.HasPrefix(trimmedLine, "--")
}

func appendNewlineIfNeeded(stmt *strings.Builder) {
	if stmt.Len() > 0 {
		stmt.WriteString("\n")
	}
}

func appendLineToStatement(stmt *strings.Builder, line string) {
	appendNewlineIfNeeded(stmt)
	stmt.WriteString(line)
}

func (p *sqlStatementParser) updateState(line string) {
	trimmedLine := strings.TrimSpace(line)
	upperLine := strings.ToUpper(trimmedLine)

	if strings.Contains(upperLine, "SETTINGS") {
		p.inSettingsBlock = true
	}

	for _, char := range line {
		switch char {
		case '(':
			p.parenthesesDepth++
		case ')':
			p.parenthesesDepth--
		}
	}
}

func (p *sqlStatementParser) shouldSplitStatement(line string) bool {
	trimmedLine := strings.TrimSpace(line)
	if !strings.HasSuffix(trimmedLine, ";") {
		return false
	}

	if p.inSettingsBlock && p.parenthesesDepth == 0 {
		p.inSettingsBlock = false
	}

	return !p.inSettingsBlock
}

func (p *sqlStatementParser) reset() {
	p.parenthesesDepth = 0
	p.inSettingsBlock = false
}

func extractStatement(stmt *strings.Builder) string {
	if stmt.Len() == 0 {
		return ""
	}

	result := strings.TrimSpace(stmt.String())
	result = strings.TrimSuffix(result, ";")
	return result
}
