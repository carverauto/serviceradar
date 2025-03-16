package auth

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/golang-jwt/jwt/v4"
)

type Claims struct {
	UserID   string `json:"user_id"`
	Email    string `json:"email"`
	Provider string `json:"provider"`
	jwt.RegisteredClaims
}

func GenerateJWT(user *models.User, secret string, expiration time.Duration) (string, error) {
	claims := Claims{
		UserID:   user.ID,
		Email:    user.Email,
		Provider: user.Provider,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(expiration)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}

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
