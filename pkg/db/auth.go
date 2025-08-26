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

// getUserByField retrieves a user by a specific field (e.g., id or email).
func (db *DB) getUserByField(ctx context.Context, field, value string) (*models.User, error) {
	user := &models.User{}

	query := `
        SELECT id, email, name, provider, created_at, updated_at
        FROM users
        WHERE ` + field + ` = $1
        LIMIT 1`

	rows, err := db.Conn.Query(ctx, query, value)
	if err != nil {
		return nil, fmt.Errorf("failed to query user by %s: %w", field, err)
	}
	defer func() { _ = rows.Close() }()

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
		return nil, fmt.Errorf("failed to scan user by %s: %w", field, err)
	}

	return user, nil
}

// GetUserByID retrieves a user by ID.
func (db *DB) GetUserByID(ctx context.Context, id string) (*models.User, error) {
	return db.getUserByField(ctx, "id", id)
}

// GetUserByEmail retrieves a user by email address.
func (db *DB) GetUserByEmail(ctx context.Context, email string) (*models.User, error) {
	return db.getUserByField(ctx, "email", email)
}

// StoreUser stores a user in the database.
func (db *DB) StoreUser(ctx context.Context, user *models.User) error {
	user.CreatedAt = time.Now()
	user.UpdatedAt = user.CreatedAt

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO users (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		user.ID,
		user.Name, // username field
		user.Email,
		"", // password_hash (empty for OAuth users)
		user.CreatedAt,
		user.UpdatedAt,
		true,                // is_active (default to true)
		[]string{"default"}, // roles (default role)
	)
	if err != nil {
		return fmt.Errorf("failed to append user: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store user: %w", err)
	}

	return nil
}

// StoreBatchUsers stores multiple users in a single batch operation
func (db *DB) StoreBatchUsers(ctx context.Context, users []*models.User) error {
	if len(users) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO users (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	now := time.Now()

	for _, user := range users {
		// Set timestamps if not already set
		if user.CreatedAt.IsZero() {
			user.CreatedAt = now
		}

		if user.UpdatedAt.IsZero() {
			user.UpdatedAt = now
		}

		err = batch.Append(
			user.ID,
			user.Name, // username field
			user.Email,
			"", // password_hash (empty for OAuth users)
			user.CreatedAt,
			user.UpdatedAt,
			true,                // is_active (default to true)
			[]string{"default"}, // roles (default role)
		)
		if err != nil {
			return fmt.Errorf("failed to append user %s: %w", user.ID, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store batch users: %w", err)
	}

	return nil
}

// UpdateUserLastSeen updates a user's last seen timestamp
func (db *DB) UpdateUserLastSeen(ctx context.Context, userID string) error {
	now := time.Now()

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO users (id, updated_at)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(userID, now)
	if err != nil {
		return fmt.Errorf("failed to append user update: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to update user last seen: %w", err)
	}

	return nil
}

// UpdateUser updates a user's information
func (db *DB) UpdateUser(ctx context.Context, user *models.User) error {
	user.UpdatedAt = time.Now()

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO users (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		user.ID,
		user.Name, // username field
		user.Email,
		"", // password_hash (empty for OAuth users)
		user.CreatedAt,
		user.UpdatedAt,
		true,                // is_active (default to true)
		[]string{"default"}, // roles (default role)
	)
	if err != nil {
		return fmt.Errorf("failed to append user update: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to update user: %w", err)
	}

	return nil
}
