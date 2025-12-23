/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/carverauto/serviceradar/pkg/logger"
)

const cnpgMigrationsTable = "cnpg_schema_migrations"

//go:embed cnpg/migrations/*.sql
var cnpgMigrationsFS embed.FS

// RunCNPGMigrations ensures the CNPG schema is hydrated with the latest Timescale tables.
func RunCNPGMigrations(ctx context.Context, pool *pgxpool.Pool, log logger.Logger) error {
	if pool == nil {
		return nil
	}

	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("cnpg migrations: acquire connection: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, fmt.Sprintf(`CREATE TABLE IF NOT EXISTS %s (
		version     TEXT PRIMARY KEY,
		applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
	)`, cnpgMigrationsTable)); err != nil {
		return fmt.Errorf("cnpg migrations: create tracking table: %w", err)
	}

	applied := make(map[string]struct{})

	rows, err := conn.Query(ctx, fmt.Sprintf(`SELECT version FROM %s`, cnpgMigrationsTable))
	if err != nil {
		return fmt.Errorf("cnpg migrations: list applied versions: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var version string
		if err := rows.Scan(&version); err != nil {
			return fmt.Errorf("cnpg migrations: scan applied version: %w", err)
		}
		applied[version] = struct{}{}
	}

	if err := rows.Err(); err != nil {
		return fmt.Errorf("cnpg migrations: iterate applied versions: %w", err)
	}

	entries, err := fs.ReadDir(cnpgMigrationsFS, "cnpg/migrations")
	if err != nil {
		return fmt.Errorf("cnpg migrations: read embedded migrations: %w", err)
	}

	filenames := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		// Only process .up.sql files; .down.sql files are for rollbacks only
		if !strings.HasSuffix(entry.Name(), ".up.sql") {
			continue
		}
		filenames = append(filenames, entry.Name())
	}

	sort.Strings(filenames)

	for _, name := range filenames {
		version := extractVersion(name)
		if _, ok := applied[version]; ok {
			continue
		}

		log.Info().Str("migration", name).Msg("applying CNPG migration")

		content, err := cnpgMigrationsFS.ReadFile("cnpg/migrations/" + name)
		if err != nil {
			return fmt.Errorf("cnpg migrations: read %s: %w", name, err)
		}

		statements := splitSQLStatements(string(content))

		for idx, statement := range statements {
			stmt := statement
			if stmt == "" {
				continue
			}

			if _, err := conn.Exec(ctx, stmt); err != nil {
				return fmt.Errorf("cnpg migrations: statement %d in %s failed: %w", idx+1, name, err)
			}
		}

		if _, err := conn.Exec(ctx, fmt.Sprintf(`INSERT INTO %s (version) VALUES ($1)`, cnpgMigrationsTable), version); err != nil {
			return fmt.Errorf("cnpg migrations: record %s: %w", name, err)
		}

		log.Info().Str("migration", name).Msg("CNPG migration complete")
	}

	return nil
}
