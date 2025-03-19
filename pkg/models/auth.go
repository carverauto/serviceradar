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
	JWTSecret     string 				`json:"jwt_secret"`
	JWTExpiration time.Duration 		`json:"jwt_expiration"`
	CallbackURL   string 				`json:"callback_url"`
	LocalUsers    map[string]string 	`json:"local_users"`
	SSOProviders  map[string]SSOConfig 	`json:"sso_providers"`
}

type SSOConfig struct {
	ClientID     string
	ClientSecret string
	Scopes       []string
}
