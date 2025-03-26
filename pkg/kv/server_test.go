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

// Package kv pkg/kv/server_test.go
package kv

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

// dummyAuthInfo is a test implementation of credentials.AuthInfo.
type dummyAuthInfo struct{}

func (dummyAuthInfo) AuthType() string {
	return "dummy"
}

// setupServer creates a Server instance with a mock KVStore and common config.
func setupServer(t *testing.T) (*Server, *MockKVStore) {
	t.Helper()

	ctrl := gomock.NewController(t)
	mockStore := NewMockKVStore(ctrl)
	config := Config{
		ListenAddr: "localhost:50051",
		Security:   &models.SecurityConfig{},
		RBAC: struct {
			Roles []RBACRule `json:"roles"`
		}{
			Roles: []RBACRule{
				{Identity: "CN=reader-client", Role: RoleReader},
				{Identity: "CN=writer-client", Role: RoleWriter},
			},
		},
	}

	return &Server{config: &config, store: mockStore}, mockStore
}

func TestExtractIdentity(t *testing.T) {
	t.Run("NoPeerInfo", func(t *testing.T) {
		s, _ := setupServer(t)
		ctx := context.Background()
		_, err := s.extractIdentity(ctx)
		require.Error(t, err)
		assert.Equal(t, codes.Unauthenticated, status.Code(err))
		assert.Contains(t, err.Error(), "no peer info available; mTLS required")
	})

	t.Run("NoTLS", func(t *testing.T) {
		s, _ := setupServer(t)
		p := &peer.Peer{AuthInfo: dummyAuthInfo{}}
		ctx := peer.NewContext(context.Background(), p)
		_, err := s.extractIdentity(ctx)
		require.Error(t, err)
		assert.Equal(t, codes.Unauthenticated, status.Code(err))
		assert.Contains(t, err.Error(), "mTLS authentication required")
	})

	t.Run("ValidTLS", func(t *testing.T) {
		s, _ := setupServer(t)
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		identity, err := s.extractIdentity(ctx)
		require.NoError(t, err)
		assert.Equal(t, "CN=reader-client", identity)
	})
}
