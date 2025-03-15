package auth

import (
	"time"

	"github.com/dgrijalva/jwt-go"
	"github.com/golang-jwt/jwt/v4"
)

type Claims struct {
	UserID   string `json:"user_id"`
	Email    string `json:"email"`
	Provider string `json:"provider"`
	jwt.StandardClaims
}

func GenerateJWT(user *User, secret string, expiration time.Duration) (string, error) {
	claims := Claims{
		UserID:   user.ID,
		Email:    user.Email,
		Provider: user.Provider,
		StandardClaims: jwt.StandardClaims{
			ExpiresAt: time.Now().Add(expiration).Unix(),
			IssuedAt:  time.Now().Unix(),
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(secret))
}

func ParseJWT(tokenString string, secret string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
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

func GenerateTokenPair(user *User, config *AuthConfig) (*Token, error) {
	accessToken, err := GenerateJWT(user, config.JWTSecret, config.JWTExpiration)
	if err != nil {
		return nil, err
	}

	refreshToken, err := GenerateJWT(user, config.JWTSecret, 7*24*time.Hour) // 1 week refresh token
	if err != nil {
		return nil, err
	}

	return &Token{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresAt:    time.Now().Add(config.JWTExpiration),
	}, nil
}
