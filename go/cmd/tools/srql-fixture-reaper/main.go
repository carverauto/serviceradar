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

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/go/pkg/srqlfixture/reaper"
)

const candidateSQL = `
SELECT d.datname,
       EXTRACT(EPOCH FROM (now() - (pg_stat_file(format('base/%s/PG_VERSION', d.oid), true)).modification)) AS age_secs,
       EXISTS (
           SELECT 1
           FROM pg_stat_activity a
           WHERE a.datname = d.datname
             AND a.backend_type = 'client backend'
             AND coalesce(a.application_name, '') NOT ILIKE 'TimescaleDB%'
             AND a.pid <> pg_backend_pid()
       ) AS live_client
FROM pg_database d
JOIN pg_tablespace t ON t.oid = d.dattablespace
WHERE NOT d.datistemplate
  AND t.spcname = 'pg_default'
`

func main() {
	var (
		dryRun   = flag.Bool("dry-run", false, "list candidates without dropping them")
		maxAge   = flag.Duration("max-age", reaper.DefaultMaxAge, "minimum age of a database before it can be dropped")
		interval = flag.Duration("interval", 0, "if > 0, run forever at this interval (daemon mode); 0 runs once")
	)
	flag.Parse()

	if err := runWithSignals(*dryRun, *maxAge, *interval); err != nil {
		fmt.Fprintf(os.Stderr, "srql-fixture-reaper: %v\n", err)
		os.Exit(1)
	}
}

func runWithSignals(dryRun bool, maxAge, interval time.Duration) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	return run(ctx, dryRun, maxAge, interval)
}

func run(ctx context.Context, dryRun bool, maxAge, interval time.Duration) error {
	if maxAge <= 0 {
		return reaper.ErrMaxAge
	}

	for {
		dropped, skipped, err := reapOnce(ctx, dryRun, maxAge)
		if err != nil {
			return err
		}

		fmt.Printf("dropped=%d skipped=%d dry-run=%t\n", dropped, skipped, dryRun)

		if interval <= 0 {
			return nil
		}

		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

func reapOnce(ctx context.Context, dryRun bool, maxAge time.Duration) (int, int, error) {
	connString := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	conn, err := pgx.Connect(ctx, connString)
	if err != nil {
		return 0, 0, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	rows, err := conn.Query(ctx, candidateSQL)
	if err != nil {
		return 0, 0, fmt.Errorf("list databases: %w", err)
	}
	defer rows.Close()

	var (
		dropped int
		skipped int
	)

	for rows.Next() {
		var (
			name       string
			ageSeconds *float64
			liveClient bool
		)

		if err := rows.Scan(&name, &ageSeconds, &liveClient); err != nil {
			return dropped, skipped, fmt.Errorf("scan: %w", err)
		}

		age := time.Duration(0)
		if ageSeconds != nil {
			age = time.Duration(*ageSeconds * float64(time.Second))
		}

		ok, reason := reaper.ShouldDrop(reaper.Database{
			Name:          name,
			Age:           age,
			HasLiveClient: liveClient,
		}, maxAge)
		if !ok {
			skipped++
			fmt.Printf("skip %s (%s)\n", name, reason)
			continue
		}

		stmt, err := reaper.DropStatement(name)
		if err != nil {
			return dropped, skipped, err
		}

		if dryRun {
			fmt.Printf("dry-run %s\n", stmt)
			dropped++
			continue
		}

		if _, err := conn.Exec(ctx, stmt); err != nil {
			fmt.Fprintf(os.Stderr, "could not drop %s: %v\n", name, err)
			skipped++
			continue
		}

		fmt.Printf("dropped %s (age %s)\n", name, age.Round(time.Second))
		dropped++
	}

	if err := rows.Err(); err != nil {
		return dropped, skipped, err
	}

	return dropped, skipped, nil
}
