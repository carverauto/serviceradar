package db

import (
	"context"
	"embed"
	"fmt"
	"log"
	"path/filepath"
	"sort"
	"strings"

	"github.com/timeplus-io/proton-go-driver/v2"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

const migrationsTable = "schema_migrations"

// RunMigrations checks for and applies all pending database migrations.
func RunMigrations(ctx context.Context, conn proton.Conn) error {
	log.Println("=== Running Database Migrations ===")

	// 1. Ensure the migrations tracking table exists.
	if err := createMigrationsTable(ctx, conn); err != nil {
		return fmt.Errorf("failed to create migrations table: %w", err)
	}

	// 2. Get the list of already applied migrations.
	appliedMigrations, err := getAppliedMigrations(ctx, conn)
	if err != nil {
		return fmt.Errorf("failed to get applied migrations: %w", err)
	}
	log.Printf("Found %d applied migrations.", len(appliedMigrations))

	// 3. Get all available migrations from the filesystem.
	availableMigrations, err := getAvailableMigrations()
	if err != nil {
		return fmt.Errorf("failed to get available migrations: %w", err)
	}
	log.Printf("Found %d available migrations.", len(availableMigrations))

	// 4. Apply any migrations that have not yet been run.
	for _, migrationFile := range availableMigrations {
		version := extractVersion(migrationFile)
		if _, ok := appliedMigrations[version]; ok {
			continue // Skip already applied migration
		}

		log.Printf("Applying migration: %s", migrationFile)

		// Read the migration content
		content, err := migrationsFS.ReadFile("migrations/" + migrationFile)
		if err != nil {
			return fmt.Errorf("failed to read migration file %s: %w", migrationFile, err)
		}

		// Execute the migration SQL
		if err := conn.Exec(ctx, string(content)); err != nil {
			return fmt.Errorf("failed to apply migration %s: %w", migrationFile, err)
		}

		// Record the migration version
		if err := recordMigration(ctx, conn, version); err != nil {
			return fmt.Errorf("failed to record migration %s: %w", migrationFile, err)
		}
		log.Printf("Successfully applied and recorded migration: %s", migrationFile)
	}

	log.Println("=== Database Migrations Finished ===")
	return nil
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
	batch, err := conn.PrepareBatch(ctx, fmt.Sprintf("INSERT INTO %s", migrationsTable))
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
