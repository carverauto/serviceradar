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
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/markbates/goth"
)

//go:generate mockgen -destination=mock_auth.go -package=auth github.com/carverauto/serviceradar/pkg/core/auth AuthService

type AuthService interface {
	LoginLocal(ctx context.Context, username, password string) (*models.Token, error)
	BeginOAuth(ctx context.Context, provider string) (string, error)
	CompleteOAuth(ctx context.Context, provider string, user *goth.User) (*models.Token, error)
	RefreshToken(ctx context.Context, refreshToken string) (*models.Token, error)
	VerifyToken(ctx context.Context, token string) (*models.User, error)
}
