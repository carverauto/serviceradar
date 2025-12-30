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

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/nats/accounts"
	"github.com/carverauto/serviceradar/proto"
)

// NATSAccountServer implements the NATSAccountService gRPC interface.
// This is a stateless service that performs NATS JWT/NKeys cryptographic operations.
// Account state (seeds, JWTs) is stored by the caller (Elixir/CNPG with AshCloak).
type NATSAccountServer struct {
	proto.UnimplementedNATSAccountServiceServer

	signer *accounts.AccountSigner
}

// NewNATSAccountServer creates a new NATSAccountServer with the given operator.
// The server is stateless - it only holds the operator key for signing operations.
func NewNATSAccountServer(operator *accounts.Operator) *NATSAccountServer {
	return &NATSAccountServer{
		signer: accounts.NewAccountSigner(operator),
	}
}

// CreateTenantAccount generates new account NKeys and a signed account JWT.
// The returned account_seed should be stored encrypted by the caller (Elixir/AshCloak).
func (s *NATSAccountServer) CreateTenantAccount(
	_ context.Context,
	req *proto.CreateTenantAccountRequest,
) (*proto.CreateTenantAccountResponse, error) {
	if req.GetTenantSlug() == "" {
		return nil, status.Error(codes.InvalidArgument, "tenant_slug is required")
	}

	// Convert proto limits to domain model
	var limits *accounts.AccountLimits
	if req.GetLimits() != nil {
		limits = protoToAccountLimits(req.GetLimits())
	}

	// Convert proto subject mappings to domain model
	var mappings []accounts.SubjectMapping
	for _, m := range req.GetSubjectMappings() {
		mappings = append(mappings, accounts.SubjectMapping{
			From: m.GetFrom(),
			To:   m.GetTo(),
		})
	}

	result, err := s.signer.CreateTenantAccount(req.GetTenantSlug(), limits, mappings)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to create tenant account: %v", err)
	}

	return &proto.CreateTenantAccountResponse{
		AccountPublicKey: result.AccountPublicKey,
		AccountSeed:      result.AccountSeed, // Caller stores this encrypted
		AccountJwt:       result.AccountJWT,
	}, nil
}

// GenerateUserCredentials creates NATS user credentials for a tenant's account.
// Requires the account_seed (from Elixir storage) to sign the user JWT.
func (s *NATSAccountServer) GenerateUserCredentials(
	_ context.Context,
	req *proto.GenerateUserCredentialsRequest,
) (*proto.GenerateUserCredentialsResponse, error) {
	if req.GetTenantSlug() == "" {
		return nil, status.Error(codes.InvalidArgument, "tenant_slug is required")
	}
	if req.GetAccountSeed() == "" {
		return nil, status.Error(codes.InvalidArgument, "account_seed is required")
	}
	if req.GetUserName() == "" {
		return nil, status.Error(codes.InvalidArgument, "user_name is required")
	}

	// Convert proto credential type to domain model
	credType := protoToCredentialType(req.GetCredentialType())

	// Convert proto permissions to domain model
	var permissions *accounts.UserPermissions
	if req.GetPermissions() != nil {
		permissions = protoToUserPermissions(req.GetPermissions())
	}

	creds, err := accounts.GenerateUserCredentials(
		req.GetTenantSlug(),
		req.GetAccountSeed(),
		req.GetUserName(),
		credType,
		permissions,
		req.GetExpirationSeconds(),
	)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to generate user credentials: %v", err)
	}

	var expiresAtUnix int64
	if !creds.ExpiresAt.IsZero() {
		expiresAtUnix = creds.ExpiresAt.Unix()
	}

	return &proto.GenerateUserCredentialsResponse{
		UserPublicKey:    creds.UserPublicKey,
		UserJwt:          creds.UserJWT,
		CredsFileContent: creds.CredsFileContent,
		ExpiresAtUnix:    expiresAtUnix,
	}, nil
}

// SignAccountJWT regenerates an account JWT with updated claims.
// Use this when revocations or limits change. Requires account_seed from Elixir storage.
func (s *NATSAccountServer) SignAccountJWT(
	_ context.Context,
	req *proto.SignAccountJWTRequest,
) (*proto.SignAccountJWTResponse, error) {
	if req.GetTenantSlug() == "" {
		return nil, status.Error(codes.InvalidArgument, "tenant_slug is required")
	}
	if req.GetAccountSeed() == "" {
		return nil, status.Error(codes.InvalidArgument, "account_seed is required")
	}

	// Convert proto limits to domain model
	var limits *accounts.AccountLimits
	if req.GetLimits() != nil {
		limits = protoToAccountLimits(req.GetLimits())
	}

	// Convert proto subject mappings to domain model
	var mappings []accounts.SubjectMapping
	for _, m := range req.GetSubjectMappings() {
		mappings = append(mappings, accounts.SubjectMapping{
			From: m.GetFrom(),
			To:   m.GetTo(),
		})
	}

	accountPublicKey, accountJWT, err := s.signer.SignAccountJWT(
		req.GetTenantSlug(),
		req.GetAccountSeed(),
		limits,
		mappings,
		req.GetRevokedUserKeys(),
	)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to sign account JWT: %v", err)
	}

	return &proto.SignAccountJWTResponse{
		AccountPublicKey: accountPublicKey,
		AccountJwt:       accountJWT,
	}, nil
}

// Helper functions for proto conversion

func protoToAccountLimits(p *proto.AccountLimits) *accounts.AccountLimits {
	if p == nil {
		return nil
	}
	return &accounts.AccountLimits{
		MaxConnections:       p.GetMaxConnections(),
		MaxSubscriptions:     p.GetMaxSubscriptions(),
		MaxPayloadBytes:      p.GetMaxPayloadBytes(),
		MaxDataBytes:         p.GetMaxDataBytes(),
		MaxExports:           p.GetMaxExports(),
		MaxImports:           p.GetMaxImports(),
		AllowWildcardExports: p.GetAllowWildcardExports(),
	}
}

func protoToCredentialType(t proto.UserCredentialType) accounts.UserCredentialType {
	switch t {
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR:
		return accounts.CredentialTypeCollector
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE:
		return accounts.CredentialTypeService
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_ADMIN:
		return accounts.CredentialTypeAdmin
	default:
		return accounts.CredentialTypeCollector
	}
}

func protoToUserPermissions(p *proto.UserPermissions) *accounts.UserPermissions {
	if p == nil {
		return nil
	}
	return &accounts.UserPermissions{
		PublishAllow:   p.GetPublishAllow(),
		PublishDeny:    p.GetPublishDeny(),
		SubscribeAllow: p.GetSubscribeAllow(),
		SubscribeDeny:  p.GetSubscribeDeny(),
		AllowResponses: p.GetAllowResponses(),
		MaxResponses:   p.GetMaxResponses(),
	}
}
