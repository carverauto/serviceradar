package auth

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/markbates/goth"
)

//go:generate mockgen -destination=mock_auth.go -package=auth github.com/carverauto/serviceradar/pkg/core/auth AuthService

type AuthService interface {
	LoginLocal(ctx context.Context, username, password string) (*models.Token, error)
	BeginOAuth(ctx context.Context, provider string) (string, error)
	CompleteOAuth(ctx context.Context, provider string, user goth.User) (*models.Token, error)
	RefreshToken(ctx context.Context, refreshToken string) (*models.Token, error)
	VerifyToken(ctx context.Context, token string) (*models.User, error)
}
