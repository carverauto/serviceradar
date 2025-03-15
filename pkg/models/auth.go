package models

import (
	"time"
)

type User struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Name      string    `json:"name"`
	Provider  string    `json:"provider"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Token struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	ExpiresAt    time.Time `json:"expires_at"`
}

type AuthConfig struct {
	JWTSecret     string
	JWTExpiration time.Duration
	CallbackURL   string
	LocalUsers    map[string]string // username:password hash
	SSOProviders  map[string]SSOConfig
}

type SSOConfig struct {
	ClientID     string
	ClientSecret string
	Scopes       []string
}
