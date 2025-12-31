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
	"sync"

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

	mu       sync.RWMutex
	operator *accounts.Operator
	signer   *accounts.AccountSigner

	// natsStore provides NATS connection for pushing JWTs to resolver
	natsStore *NATSStore

	// systemAccountSeed is stored after bootstrap for JWT push operations
	systemAccountSeed string
}

// NewNATSAccountServer creates a new NATSAccountServer with the given operator.
// The server is stateless - it only holds the operator key for signing operations.
// If operator is nil, the server will start in uninitialized state and require bootstrap.
func NewNATSAccountServer(operator *accounts.Operator) *NATSAccountServer {
	server := &NATSAccountServer{
		operator: operator,
	}
	if operator != nil {
		server.signer = accounts.NewAccountSigner(operator)
	}
	return server
}

// SetNATSStore sets the NATS store for JWT push operations.
// Must be called before PushAccountJWT can work.
func (s *NATSAccountServer) SetNATSStore(store *NATSStore) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.natsStore = store
}

// BootstrapOperator initializes the NATS operator for the platform.
// This can either generate a new operator key pair or import an existing seed.
// Should be called once during initial platform setup.
func (s *NATSAccountServer) BootstrapOperator(
	_ context.Context,
	req *proto.BootstrapOperatorRequest,
) (*proto.BootstrapOperatorResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if already initialized
	if s.operator != nil && s.operator.IsInitialized() {
		return nil, status.Error(codes.AlreadyExists, "operator already initialized")
	}

	operatorName := req.GetOperatorName()
	if operatorName == "" {
		operatorName = "serviceradar"
	}

	// Bootstrap the operator (generates new or imports existing)
	operator, result, err := accounts.BootstrapOperator(
		operatorName,
		req.GetExistingOperatorSeed(),
		req.GetGenerateSystemAccount(),
	)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to bootstrap operator: %v", err)
	}

	// Update the server state
	s.operator = operator
	s.signer = accounts.NewAccountSigner(operator)

	// Store system account seed for JWT push operations
	if result.SystemAccountSeed != "" {
		s.systemAccountSeed = result.SystemAccountSeed
	}

	return &proto.BootstrapOperatorResponse{
		OperatorPublicKey:       result.OperatorPublicKey,
		OperatorSeed:            result.OperatorSeed, // Only set if newly generated
		OperatorJwt:             result.OperatorJWT,
		SystemAccountPublicKey:  result.SystemAccountPublicKey,
		SystemAccountSeed:       result.SystemAccountSeed,
		SystemAccountJwt:        result.SystemAccountJWT,
	}, nil
}

// GetOperatorInfo returns the current operator status and public key.
// Used to verify the operator is initialized before tenant operations.
func (s *NATSAccountServer) GetOperatorInfo(
	_ context.Context,
	_ *proto.GetOperatorInfoRequest,
) (*proto.GetOperatorInfoResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.operator == nil || !s.operator.IsInitialized() {
		return &proto.GetOperatorInfoResponse{
			IsInitialized: false,
		}, nil
	}

	return &proto.GetOperatorInfoResponse{
		OperatorPublicKey:       s.operator.PublicKey(),
		OperatorName:            s.operator.Name(),
		IsInitialized:           true,
		SystemAccountPublicKey:  s.operator.SystemAccountPublicKey(),
	}, nil
}

// ensureInitialized checks if the operator is initialized and returns the signer.
// Must be called with at least a read lock held.
func (s *NATSAccountServer) ensureInitialized() (*accounts.AccountSigner, error) {
	if s.operator == nil || s.signer == nil {
		return nil, status.Error(codes.FailedPrecondition, "operator not initialized - call BootstrapOperator first")
	}
	return s.signer, nil
}

// CreateTenantAccount generates new account NKeys and a signed account JWT.
// The returned account_seed should be stored encrypted by the caller (Elixir/AshCloak).
func (s *NATSAccountServer) CreateTenantAccount(
	_ context.Context,
	req *proto.CreateTenantAccountRequest,
) (*proto.CreateTenantAccountResponse, error) {
	s.mu.RLock()
	signer, err := s.ensureInitialized()
	s.mu.RUnlock()
	if err != nil {
		return nil, err
	}

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

	result, err := signer.CreateTenantAccount(req.GetTenantSlug(), limits, mappings)
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
	s.mu.RLock()
	signer, err := s.ensureInitialized()
	s.mu.RUnlock()
	if err != nil {
		return nil, err
	}

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

	accountPublicKey, accountJWT, err := signer.SignAccountJWT(
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

// PushAccountJWT pushes an account JWT to the NATS resolver.
// This makes the account immediately available without NATS restart.
// Uses the $SYS.REQ.CLAIMS.UPDATE subject via the system account.
func (s *NATSAccountServer) PushAccountJWT(
	ctx context.Context,
	req *proto.PushAccountJWTRequest,
) (*proto.PushAccountJWTResponse, error) {
	if req.GetAccountPublicKey() == "" {
		return nil, status.Error(codes.InvalidArgument, "account_public_key is required")
	}
	if req.GetAccountJwt() == "" {
		return nil, status.Error(codes.InvalidArgument, "account_jwt is required")
	}

	s.mu.RLock()
	store := s.natsStore
	s.mu.RUnlock()

	if store == nil {
		return nil, status.Error(codes.FailedPrecondition, "NATS store not configured - cannot push JWT")
	}

	// The NATS resolver listens on $SYS.REQ.CLAIMS.UPDATE for new account JWTs.
	// We publish the JWT and wait for a response.
	// Note: This requires the connection to have permission to publish to $SYS subjects.
	// In a production setup, this would use the system account credentials.
	subject := "$SYS.REQ.CLAIMS.UPDATE"

	store.mu.Lock()
	nc := store.nc
	store.mu.Unlock()

	if nc == nil {
		return nil, status.Error(codes.FailedPrecondition, "NATS not connected")
	}

	// Publish the JWT to the claims update subject
	// The NATS server will validate and store the JWT in the resolver
	msg, err := nc.RequestWithContext(ctx, subject, []byte(req.GetAccountJwt()))
	if err != nil {
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: "failed to push JWT to resolver: " + err.Error(),
		}, nil
	}

	// Parse the response - NATS returns an empty message on success
	// or an error message on failure
	responseMsg := string(msg.Data)
	if responseMsg != "" && responseMsg[0] == '-' {
		// Error response starts with -ERR
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: "resolver rejected JWT: " + responseMsg,
		}, nil
	}

	return &proto.PushAccountJWTResponse{
		Success: true,
		Message: "JWT pushed to resolver successfully",
	}, nil
}
