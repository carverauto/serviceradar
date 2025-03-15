package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (db *DB) StoreUser(user *models.User) error {
	user.CreatedAt = time.Now()
	user.UpdatedAt = user.CreatedAt

	_, err := db.Exec(`
        INSERT INTO users (id, email, name, provider, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            email = excluded.email,
            name = excluded.name,
            updated_at = excluded.updated_at
    `, user.ID, user.Email, user.Name, user.Provider, user.CreatedAt, user.UpdatedAt)
	if err != nil {
		return fmt.Errorf("failed to store user: %w", err)
	}
	return nil
}

func (db *DB) GetUserByID(id string) (*models.User, error) {
	user := &models.User{}
	err := db.QueryRow(`
        SELECT id, email, name, provider, created_at, updated_at
        FROM users WHERE id = ?
    `, id).Scan(&user.ID, &user.Email, &user.Name, &user.Provider, &user.CreatedAt, &user.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get user: %w", err)
	}
	return user, nil
}
