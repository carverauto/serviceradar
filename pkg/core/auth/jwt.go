/*
 * Copyright 2025 Carver Automation Corporation.
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

package auth

import (
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v4"

	"github.com/carverauto/serviceradar/pkg/models"
)

type Claims struct {
	UserID   string   `json:"user_id"`
	Email    string   `json:"email"`
	Provider string   `json:"provider"`
	Roles    []string `json:"roles"`
	jwt.RegisteredClaims
}

func GenerateJWT(user *models.User, secret string, expiration time.Duration) (string, error) {
	// Debug logging
	fmt.Printf("DEBUG: GenerateJWT - User ID: %s, Email: %s, Provider: %s\n", user.ID, user.Email, user.Provider)
	fmt.Printf("DEBUG: GenerateJWT - User Roles: %+v\n", user.Roles)

	claims := Claims{
		UserID:   user.ID,
		Email:    user.Email,
		Provider: user.Provider,
		Roles:    user.Roles,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(expiration)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}

	fmt.Printf("DEBUG: GenerateJWT - Claims Roles: %+v\n", claims.Roles)

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)

	return token.SignedString([]byte(secret))
}

func ParseJWT(tokenString, secret string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(*jwt.Token) (interface{}, error) {
		return []byte(secret), nil
	})
	if err != nil {
		return nil, err
	}

	if claims, ok := token.Claims.(*Claims); ok && token.Valid {
		return claims, nil
	}

	return nil, jwt.ErrSignatureInvalid
}

func GenerateTokenPair(user *models.User, config *models.AuthConfig) (*models.Token, error) {
	accessToken, err := GenerateJWT(user, config.JWTSecret, config.JWTExpiration)
	if err != nil {
		return nil, err
	}

	refreshToken, err := GenerateJWT(user, config.JWTSecret, 7*24*time.Hour) // 1 week refresh token
	if err != nil {
		return nil, err
	}

	return &models.Token{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresAt:    time.Now().Add(config.JWTExpiration),
	}, nil
}
