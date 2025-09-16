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
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
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

const algorithmRS256 = "RS256"

var (
	errUnsupportedJWTAlgorithm = errors.New("unsupported JWT algorithm")
	errUnexpectedSigningMethod = errors.New("unexpected signing method")
	errEmptyJWTPrivateKeyPEM   = errors.New("JWTPrivateKeyPEM is empty")
	errInvalidRSAPrivateKeyPEM = errors.New("invalid RSA private key PEM")
	errNotRSAPrivateKey        = errors.New("provided key is not RSA private key")
	errInvalidRSAPublicKeyPEM  = errors.New("invalid RSA public key PEM")
	errNotRSAPublicKey         = errors.New("not an RSA public key")
)

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
	accessToken, err := GenerateJWTConfig(user, config, config.JWTExpiration)
	if err != nil {
		return nil, err
	}

	refreshToken, err := GenerateJWTConfig(user, config, 7*24*time.Hour) // 1 week refresh token
	if err != nil {
		return nil, err
	}

	return &models.Token{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresAt:    time.Now().Add(config.JWTExpiration),
	}, nil
}

// GenerateJWTConfig generates a JWT using the configured algorithm.
func GenerateJWTConfig(user *models.User, cfg *models.AuthConfig, expiration time.Duration) (string, error) {
	if cfg == nil || cfg.JWTAlgorithm == "" || cfg.JWTAlgorithm == "HS256" {
		return GenerateJWT(user, cfg.JWTSecret, expiration)
	}

	// Build claims
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

	switch cfg.JWTAlgorithm {
	case algorithmRS256:
		priv, kid, err := parseRSAPrivateKey(cfg.JWTPrivateKeyPEM, cfg.JWTKeyID)
		if err != nil {
			return "", err
		}
		token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
		if kid != "" {
			token.Header["kid"] = kid
		}
		return token.SignedString(priv)
	default:
		return "", fmt.Errorf("%w: %s", errUnsupportedJWTAlgorithm, cfg.JWTAlgorithm)
	}
}

// ParseJWTConfig verifies a JWT using the configured algorithm.
func ParseJWTConfig(tokenString string, cfg *models.AuthConfig) (*Claims, error) {
	if cfg == nil || cfg.JWTAlgorithm == "" || cfg.JWTAlgorithm == "HS256" {
		return ParseJWT(tokenString, cfg.JWTSecret)
	}

	switch cfg.JWTAlgorithm {
	case algorithmRS256:
		// Prefer public key PEM if provided, otherwise derive from private key
		var pubKey *rsa.PublicKey
		if cfg.JWTPublicKeyPEM != "" {
			pk, err := parseRSAPublicKey(cfg.JWTPublicKeyPEM)
			if err != nil {
				return nil, err
			}
			pubKey = pk
		} else {
			priv, _, err := parseRSAPrivateKey(cfg.JWTPrivateKeyPEM, cfg.JWTKeyID)
			if err != nil {
				return nil, err
			}
			pubKey = &priv.PublicKey
		}
		token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(t *jwt.Token) (interface{}, error) {
			if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
				return nil, fmt.Errorf("%w: %v", errUnexpectedSigningMethod, t.Header["alg"])
			}
			return pubKey, nil
		})
		if err != nil {
			return nil, err
		}
		if claims, ok := token.Claims.(*Claims); ok && token.Valid {
			return claims, nil
		}
		return nil, jwt.ErrSignatureInvalid
	default:
		return nil, fmt.Errorf("%w: %s", errUnsupportedJWTAlgorithm, cfg.JWTAlgorithm)
	}
}

func parseRSAPrivateKey(pemStr, kid string) (*rsa.PrivateKey, string, error) {
	if pemStr == "" {
		return nil, "", errEmptyJWTPrivateKeyPEM
	}
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil || block.Type != "RSA PRIVATE KEY" && block.Type != "PRIVATE KEY" {
		return nil, "", errInvalidRSAPrivateKeyPEM
	}
	var key any
	var err error
	if block.Type == "PRIVATE KEY" {
		key, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, "", fmt.Errorf("parse PKCS8 private key: %w", err)
		}
	} else {
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return nil, "", fmt.Errorf("parse PKCS1 private key: %w", err)
		}
	}
	priv, ok := key.(*rsa.PrivateKey)
	if !ok {
		return nil, "", errNotRSAPrivateKey
	}
	return priv, kid, nil
}

func parseRSAPublicKey(pemStr string) (*rsa.PublicKey, error) {
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil || (block.Type != "PUBLIC KEY" && block.Type != "RSA PUBLIC KEY") {
		return nil, errInvalidRSAPublicKeyPEM
	}
	if block.Type == "PUBLIC KEY" {
		pkix, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse PKIX public key: %w", err)
		}
		pub, ok := pkix.(*rsa.PublicKey)
		if !ok {
			return nil, errNotRSAPublicKey
		}
		return pub, nil
	}
	pub, err := x509.ParsePKCS1PublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PKCS1 public key: %w", err)
	}
	return pub, nil
}
