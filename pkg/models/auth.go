package models

import (
	"encoding/json"
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
	JWTSecret     string               `json:"jwt_secret""`
	JWTExpiration time.Duration        `json:"jwt_expiration"`
	CallbackURL   string               `json:"callback_url"`
	LocalUsers    map[string]string    `json:"local_users"`
	SSOProviders  map[string]SSOConfig `json:"sso_providers"`
}

type SSOConfig struct {
	ClientID     string
	ClientSecret string
	Scopes       []string
}

// UnmarshalJSON implements the json.Unmarshaler interface for AuthConfig.
func (a *AuthConfig) UnmarshalJSON(data []byte) error {
	// Define an auxiliary struct to handle the string parsing
	type Alias AuthConfig
	aux := struct {
		JWTExpiration string `json:"jwt_expiration"` // Temporarily store as string
		*Alias
	}{
		Alias: (*Alias)(a),
	}

	// Unmarshal into the auxiliary struct
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}

	// Parse the JWTExpiration string into a time.Duration
	if aux.JWTExpiration != "" {
		duration, err := time.ParseDuration(aux.JWTExpiration)
		if err != nil {
			return err // This will propagate the error up to LoadConfig
		}
		a.JWTExpiration = duration
	}

	return nil
}
