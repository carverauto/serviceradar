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

package datasvc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/nats/accounts"
	"github.com/carverauto/serviceradar/proto"
)

func newTestNATSAccountServer(t *testing.T) *NATSAccountServer {
	t.Helper()

	// Generate a test operator
	seed, _, err := accounts.GenerateOperatorKey()
	if err != nil {
		t.Fatalf("Failed to generate operator key: %v", err)
	}

	cfg := &accounts.OperatorConfig{
		Name:         "test-operator",
		OperatorSeed: seed,
	}

	operator, err := accounts.NewOperator(cfg)
	if err != nil {
		t.Fatalf("Failed to create operator: %v", err)
	}

	server := NewNATSAccountServer(operator)
	server.SetAllowedClientIdentities([]string{"CN=core.serviceradar,O=ServiceRadar"})
	return server
}

func authorizedContext() context.Context {
	cert := &x509.Certificate{
		Subject: pkix.Name{
			CommonName:   "core.serviceradar",
			Organization: []string{"ServiceRadar"},
		},
	}
	tlsInfo := credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}}
	p := &peer.Peer{AuthInfo: tlsInfo}
	return peer.NewContext(context.Background(), p)
}

func TestNATSAccountServer_CreateTenantAccount(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	t.Run("success", func(t *testing.T) {
		req := &proto.CreateTenantAccountRequest{
			TenantSlug: "acme-corp",
		}

		resp, err := server.CreateTenantAccount(ctx, req)
		if err != nil {
			t.Fatalf("CreateTenantAccount failed: %v", err)
		}

		if resp.AccountPublicKey == "" {
			t.Error("Expected non-empty account public key")
		}
		if !strings.HasPrefix(resp.AccountPublicKey, "A") {
			t.Errorf("Account public key should start with 'A', got: %s", resp.AccountPublicKey)
		}

		if resp.AccountSeed == "" {
			t.Error("Expected non-empty account seed")
		}
		if !strings.HasPrefix(resp.AccountSeed, "SA") {
			t.Errorf("Account seed should start with 'SA', got: %s", resp.AccountSeed[:2])
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("with limits", func(t *testing.T) {
		req := &proto.CreateTenantAccountRequest{
			TenantSlug: "limited-tenant",
			Limits: &proto.AccountLimits{
				MaxConnections:   100,
				MaxSubscriptions: 1000,
			},
		}

		resp, err := server.CreateTenantAccount(ctx, req)
		if err != nil {
			t.Fatalf("CreateTenantAccount with limits failed: %v", err)
		}

		if resp.AccountPublicKey == "" {
			t.Error("Expected non-empty account public key")
		}
	})

	t.Run("with subject mappings", func(t *testing.T) {
		req := &proto.CreateTenantAccountRequest{
			TenantSlug: "mapped-tenant",
			SubjectMappings: []*proto.SubjectMapping{
				{From: "events.>", To: "mapped.events.>"},
			},
		}

		resp, err := server.CreateTenantAccount(ctx, req)
		if err != nil {
			t.Fatalf("CreateTenantAccount with mappings failed: %v", err)
		}

		if resp.AccountPublicKey == "" {
			t.Error("Expected non-empty account public key")
		}
	})

	t.Run("empty tenant slug", func(t *testing.T) {
		req := &proto.CreateTenantAccountRequest{
			TenantSlug: "",
		}

		_, err := server.CreateTenantAccount(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty tenant slug")
		}

		st, ok := status.FromError(err)
		if !ok {
			t.Fatalf("Expected gRPC status error, got: %v", err)
		}
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})
}

func TestNATSAccountServer_GenerateUserCredentials(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	// First create an account to get a valid seed
	createResp, err := server.CreateTenantAccount(ctx, &proto.CreateTenantAccountRequest{
		TenantSlug: "test-tenant",
	})
	if err != nil {
		t.Fatalf("Failed to create test account: %v", err)
	}

	t.Run("success with collector type", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			TenantSlug:     "test-tenant",
			AccountSeed:    createResp.AccountSeed,
			UserName:       "collector-1",
			CredentialType: proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR,
		}

		resp, err := server.GenerateUserCredentials(ctx, req)
		if err != nil {
			t.Fatalf("GenerateUserCredentials failed: %v", err)
		}

		if resp.UserPublicKey == "" {
			t.Error("Expected non-empty user public key")
		}
		if !strings.HasPrefix(resp.UserPublicKey, "U") {
			t.Errorf("User public key should start with 'U', got: %s", resp.UserPublicKey)
		}

		if resp.UserJwt == "" {
			t.Error("Expected non-empty user JWT")
		}

		if resp.CredsFileContent == "" {
			t.Error("Expected non-empty creds file content")
		}
		if !strings.Contains(resp.CredsFileContent, "BEGIN NATS USER JWT") {
			t.Error("Creds file should contain JWT header")
		}
	})

	t.Run("with expiration", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			TenantSlug:        "test-tenant",
			AccountSeed:       createResp.AccountSeed,
			UserName:          "expiring-user",
			CredentialType:    proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE,
			ExpirationSeconds: 3600, // 1 hour
		}

		resp, err := server.GenerateUserCredentials(ctx, req)
		if err != nil {
			t.Fatalf("GenerateUserCredentials with expiration failed: %v", err)
		}

		if resp.ExpiresAtUnix == 0 {
			t.Error("Expected non-zero expiration timestamp")
		}
	})

	t.Run("empty tenant slug", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			TenantSlug:  "",
			AccountSeed: createResp.AccountSeed,
			UserName:    "test-user",
		}

		_, err := server.GenerateUserCredentials(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty tenant slug")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty account seed", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			TenantSlug:  "test-tenant",
			AccountSeed: "",
			UserName:    "test-user",
		}

		_, err := server.GenerateUserCredentials(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty account seed")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty user name", func(t *testing.T) {
		req := &proto.GenerateUserCredentialsRequest{
			TenantSlug:  "test-tenant",
			AccountSeed: createResp.AccountSeed,
			UserName:    "",
		}

		_, err := server.GenerateUserCredentials(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty user name")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})
}

func TestNATSAccountServer_SignAccountJWT(t *testing.T) {
	server := newTestNATSAccountServer(t)
	ctx := authorizedContext()

	// First create an account to get a valid seed
	createResp, err := server.CreateTenantAccount(ctx, &proto.CreateTenantAccountRequest{
		TenantSlug: "resign-tenant",
	})
	if err != nil {
		t.Fatalf("Failed to create test account: %v", err)
	}

	t.Run("success", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			TenantSlug:  "resign-tenant",
			AccountSeed: createResp.AccountSeed,
		}

		resp, err := server.SignAccountJWT(ctx, req)
		if err != nil {
			t.Fatalf("SignAccountJWT failed: %v", err)
		}

		if resp.AccountPublicKey != createResp.AccountPublicKey {
			t.Errorf("Public key mismatch: got %s, want %s",
				resp.AccountPublicKey, createResp.AccountPublicKey)
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("with revocations", func(t *testing.T) {
		// First generate a user to revoke
		userResp, err := server.GenerateUserCredentials(ctx, &proto.GenerateUserCredentialsRequest{
			TenantSlug:  "resign-tenant",
			AccountSeed: createResp.AccountSeed,
			UserName:    "revoke-me",
		})
		if err != nil {
			t.Fatalf("Failed to create user: %v", err)
		}

		req := &proto.SignAccountJWTRequest{
			TenantSlug:      "resign-tenant",
			AccountSeed:     createResp.AccountSeed,
			RevokedUserKeys: []string{userResp.UserPublicKey},
		}

		resp, err := server.SignAccountJWT(ctx, req)
		if err != nil {
			t.Fatalf("SignAccountJWT with revocations failed: %v", err)
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("with updated limits", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			TenantSlug:  "resign-tenant",
			AccountSeed: createResp.AccountSeed,
			Limits: &proto.AccountLimits{
				MaxConnections: 200,
			},
		}

		resp, err := server.SignAccountJWT(ctx, req)
		if err != nil {
			t.Fatalf("SignAccountJWT with limits failed: %v", err)
		}

		if resp.AccountJwt == "" {
			t.Error("Expected non-empty account JWT")
		}
	})

	t.Run("empty tenant slug", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			TenantSlug:  "",
			AccountSeed: createResp.AccountSeed,
		}

		_, err := server.SignAccountJWT(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty tenant slug")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})

	t.Run("empty account seed", func(t *testing.T) {
		req := &proto.SignAccountJWTRequest{
			TenantSlug:  "resign-tenant",
			AccountSeed: "",
		}

		_, err := server.SignAccountJWT(ctx, req)
		if err == nil {
			t.Fatal("Expected error for empty account seed")
		}

		st, _ := status.FromError(err)
		if st.Code() != codes.InvalidArgument {
			t.Errorf("Expected InvalidArgument, got: %v", st.Code())
		}
	})
}

func TestProtoConversions(t *testing.T) {
	t.Run("protoToAccountLimits nil", func(t *testing.T) {
		result := protoToAccountLimits(nil)
		if result != nil {
			t.Error("Expected nil for nil input")
		}
	})

	t.Run("protoToAccountLimits with values", func(t *testing.T) {
		proto := &proto.AccountLimits{
			MaxConnections:       100,
			MaxSubscriptions:     1000,
			MaxPayloadBytes:      1048576,
			MaxDataBytes:         10485760,
			MaxExports:           10,
			MaxImports:           20,
			AllowWildcardExports: true,
		}

		result := protoToAccountLimits(proto)

		if result.MaxConnections != 100 {
			t.Errorf("MaxConnections: got %d, want 100", result.MaxConnections)
		}
		if result.MaxSubscriptions != 1000 {
			t.Errorf("MaxSubscriptions: got %d, want 1000", result.MaxSubscriptions)
		}
		if !result.AllowWildcardExports {
			t.Error("AllowWildcardExports should be true")
		}
	})

	t.Run("protoToCredentialType", func(t *testing.T) {
		tests := []struct {
			input proto.UserCredentialType
			want  accounts.UserCredentialType
		}{
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR, accounts.CredentialTypeCollector},
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE, accounts.CredentialTypeService},
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_ADMIN, accounts.CredentialTypeAdmin},
			{proto.UserCredentialType_USER_CREDENTIAL_TYPE_UNSPECIFIED, accounts.CredentialTypeCollector},
		}

		for _, tt := range tests {
			got := protoToCredentialType(tt.input)
			if got != tt.want {
				t.Errorf("protoToCredentialType(%v) = %v, want %v", tt.input, got, tt.want)
			}
		}
	})

	t.Run("protoToUserPermissions nil", func(t *testing.T) {
		result := protoToUserPermissions(nil)
		if result != nil {
			t.Error("Expected nil for nil input")
		}
	})

	t.Run("protoToUserPermissions with values", func(t *testing.T) {
		proto := &proto.UserPermissions{
			PublishAllow:   []string{"events.>"},
			PublishDeny:    []string{"admin.>"},
			SubscribeAllow: []string{"events.>"},
			SubscribeDeny:  []string{},
			AllowResponses: true,
			MaxResponses:   10,
		}

		result := protoToUserPermissions(proto)

		if len(result.PublishAllow) != 1 || result.PublishAllow[0] != "events.>" {
			t.Errorf("PublishAllow: got %v, want [events.>]", result.PublishAllow)
		}
		if !result.AllowResponses {
			t.Error("AllowResponses should be true")
		}
		if result.MaxResponses != 10 {
			t.Errorf("MaxResponses: got %d, want 10", result.MaxResponses)
		}
	})
}
