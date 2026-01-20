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
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Static errors for err113 compliance
var (
	ErrDatabaseNotInitialized = errors.New("database connection not initialized")
	ErrCNPGUnavailable        = errors.New("cnpg connection pool not configured")
	ErrUnknownExecutorType    = errors.New("unknown executor type")
)

// PgxExecutor is an interface satisfied by both *pgxpool.Pool and pgx.Tx
type PgxExecutor interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	SendBatch(ctx context.Context, b *pgx.Batch) pgx.BatchResults
}

// DB represents the CNPG-backed database connection.
type DB struct {
	pgPool   *pgxpool.Pool
	executor PgxExecutor
	logger   logger.Logger
}

// New creates a new CNPG-backed database connection.
func New(ctx context.Context, config *models.CoreServiceConfig, log logger.Logger) (Service, error) {
	if config == nil {
		return nil, fmt.Errorf("%w: database configuration missing", ErrFailedOpenDB)
	}

	cnpgPool, err := newCNPGPool(ctx, config, log)
	if err != nil {
		return nil, err
	}

	if cnpgPool == nil {
		return nil, fmt.Errorf("%w: CNPG configuration not provided", ErrFailedOpenDB)
	}

	db := &DB{
		pgPool:   cnpgPool,
		executor: cnpgPool, // Default to pool
		logger:   log,
	}

	return db, nil
}

func (db *DB) cnpgConfigured() bool {
	return db != nil && db.executor != nil
}

func (db *DB) UseCNPGReads() bool {
	return db.cnpgConfigured()
}

func (db *DB) UseCNPGWrites() bool {
	return db.useCNPGWrites()
}

func (db *DB) useCNPGWrites() bool {
	return db.cnpgConfigured()
}

func (db *DB) conn() PgxExecutor {
	if db.executor != nil {
		return db.executor
	}
	return db.pgPool
}

// Close closes the database connection.
func (db *DB) Close() error {
	if db.pgPool != nil {
		db.pgPool.Close()
	}

	return nil
}

// WithTx executes the given function within a transaction.
func (db *DB) WithTx(ctx context.Context, fn func(tx Service) error) error {
	if db.pgPool == nil {
		return ErrCNPGUnavailable
	}

	// If we are already in a transaction, we can create a savepoint (nested tx)
	// but simpler for now to just reuse the executor if it's already a tx,
	// OR if it's the pool, start a new tx.
	// Since db.executor is initialized to pgPool, checking type is safer.

	var tx pgx.Tx
	var err error

	if _, ok := db.executor.(*pgxpool.Pool); ok {
		// Start a new transaction from the pool
		tx, err = db.pgPool.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin tx: %w", err)
		}
	} else if currentTx, ok := db.executor.(pgx.Tx); ok {
		// Already in a transaction, create a nested transaction (savepoint)
		tx, err = currentTx.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin nested tx: %w", err)
		}
	} else {
		return ErrUnknownExecutorType
	}

	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback(ctx)
			panic(p)
		}
	}()

	// Create a shallow copy of DB using the transaction executor
	txDB := &DB{
		pgPool:   db.pgPool, // Keep pool reference for access to stateless methods if needed
		executor: tx,
		logger:   db.logger,
	}

	if err := fn(txDB); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}

	return nil
}
