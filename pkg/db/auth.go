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
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// StoreUser stores a user in the database.
func (db *DB) StoreUser(ctx context.Context, user *models.User) error {
	user.CreatedAt = time.Now()
	user.UpdatedAt = user.CreatedAt

	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO users (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		user.ID,
		user.Email,
		user.Name,
		user.Provider,
		user.CreatedAt,
		user.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("failed to append user: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store user: %w", err)
	}

	return nil
}

// GetUserByID retrieves a user by ID.
func (db *DB) GetUserByID(ctx context.Context, id string) (*models.User, error) {
	user := &models.User{}

	rows, err := db.conn.Query(ctx, `
		SELECT id, email, name, provider, created_at, updated_at
		FROM users
		WHERE id = $1
		LIMIT 1`,
		id)
	if err != nil {
		return nil, fmt.Errorf("failed to query user: %w", err)
	}
	defer rows.Close()

	if !rows.Next() {
		return nil, ErrUserNotFound
	}

	err = rows.Scan(
		&user.ID,
		&user.Email,
		&user.Name,
		&user.Provider,
		&user.CreatedAt,
		&user.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to scan user: %w", err)
	}

	return user, nil
}
