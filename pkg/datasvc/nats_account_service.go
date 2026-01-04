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
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/pkg/models"
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

	// resolverBasePath is the base directory for NATS JWT resolver files.
	// This is only needed for file-based resolvers (dev or legacy setups).
	resolverBasePath string

	// operatorConfigPath is where operator.conf is written for NATS to include
	operatorConfigPath string

	// resolverConfig controls NATS system account access for pushing JWT updates.
	resolverURL       string
	resolverSecurity  *models.SecurityConfig
	resolverCredsFile string
	resolverConn      *nats.Conn

	// allowedClientIdentities restricts access to NATS account operations.
	allowedClientIdentities map[string]struct{}
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

// SetResolverPaths configures the paths for file-based JWT resolver.
// operatorConfigPath: where to write operator.conf for NATS to include
// resolverBasePath: base directory for account JWT files
func (s *NATSAccountServer) SetResolverPaths(operatorConfigPath, resolverBasePath string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.operatorConfigPath = operatorConfigPath
	s.resolverBasePath = resolverBasePath
}

// SetResolverClient configures how account JWTs are pushed to the NATS resolver.
// credsFile should point to a system-account .creds file authorized for $SYS updates.
func (s *NATSAccountServer) SetResolverClient(natsURL string, security *models.SecurityConfig, credsFile string) {
	s.mu.Lock()

	s.resolverURL = strings.TrimSpace(natsURL)
	s.resolverSecurity = cloneSecurityConfig(security)
	s.resolverCredsFile = strings.TrimSpace(credsFile)

	conn := s.resolverConn
	s.resolverConn = nil
	s.mu.Unlock()

	if conn != nil {
		// Drain may block; do it asynchronously to avoid hanging resolver updates.
		go func() {
			_ = conn.Drain()
			conn.Close()
		}()
	}
}

// SetAllowedClientIdentities configures which mTLS identities may call this service.
func (s *NATSAccountServer) SetAllowedClientIdentities(identities []string) {
	allowed := make(map[string]struct{}, len(identities))
	for _, identity := range identities {
		trimmed := strings.TrimSpace(identity)
		if trimmed == "" {
			continue
		}
		allowed[trimmed] = struct{}{}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.allowedClientIdentities = allowed
}

func (s *NATSAccountServer) authorizeRequest(ctx context.Context) error {
	identity, err := extractMTLSIdentity(ctx)
	if err != nil {
		return err
	}

	s.mu.RLock()
	allowed := s.allowedClientIdentities
	s.mu.RUnlock()

	if len(allowed) == 0 {
		return status.Error(codes.PermissionDenied, "no allowed identities configured for NATS account service")
	}

	if _, ok := allowed[identity]; !ok {
		return status.Errorf(codes.PermissionDenied, "identity %s not authorized for NATS account service", identity)
	}

	return nil
}

func extractMTLSIdentity(ctx context.Context) (string, error) {
	p, ok := peer.FromContext(ctx)
	if !ok || p.AuthInfo == nil {
		return "", status.Error(codes.Unauthenticated, "no peer info available; mTLS required")
	}

	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.PeerCertificates) == 0 {
		return "", status.Error(codes.Unauthenticated, "mTLS authentication required")
	}

	cert := tlsInfo.State.PeerCertificates[0]
	if id := spiffeIDFromCertificate(cert); id != "" {
		return id, nil
	}

	return subjectIdentity(cert), nil
}

func (s *NATSAccountServer) getResolverConn() (*nats.Conn, error) {
	s.mu.Lock()
	resolverURL := s.resolverURL
	resolverSecurity := s.resolverSecurity
	resolverCredsFile := s.resolverCredsFile

	if resolverURL == "" {
		s.mu.Unlock()
		return nil, errResolverURLNotSet
	}

	if s.resolverConn != nil && s.resolverConn.IsConnected() {
		conn := s.resolverConn
		s.mu.Unlock()
		return conn, nil
	}

	conn := s.resolverConn
	s.resolverConn = nil
	s.mu.Unlock()

	if conn != nil {
		// Drain may block; do it asynchronously to avoid hanging resolver reconnection.
		go func() {
			drainDone := make(chan struct{})
			go func() {
				_ = conn.Drain()
				close(drainDone)
			}()

			timer := time.NewTimer(5 * time.Second)
			defer timer.Stop()

			select {
			case <-drainDone:
				conn.Close()
			case <-timer.C:
				conn.Close()
			}
		}()
	}

	opts, err := buildResolverOptions(resolverSecurity, resolverCredsFile)
	if err != nil {
		return nil, err
	}

	conn, err = nats.Connect(resolverURL, opts...)
	if err != nil {
		return nil, fmt.Errorf("connect resolver NATS: %w", err)
	}

	s.mu.Lock()
	s.resolverConn = conn
	s.mu.Unlock()
	return conn, nil
}

func buildResolverOptions(security *models.SecurityConfig, credsFile string) ([]nats.Option, error) {
	if security == nil {
		return nil, errResolverTLSRequired
	}

	tlsConfig, err := getTLSConfig(security)
	if err != nil {
		return nil, fmt.Errorf("resolver TLS config invalid: %w", err)
	}

	opts := []nats.Option{
		nats.Secure(tlsConfig),
		nats.RootCAs(security.TLS.CAFile),
		nats.ClientCert(security.TLS.CertFile, security.TLS.KeyFile),
	}

	if credsFile != "" {
		opts = append(opts, nats.UserCredentials(credsFile))
	}

	return opts, nil
}

// WriteOperatorConfig writes the operator configuration file for NATS.
// This includes the operator JWT and system account configuration.
// Must be called after BootstrapOperator to enable JWT-based account resolution.
func (s *NATSAccountServer) WriteOperatorConfig() error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.operatorConfigPath == "" {
		return errOperatorConfigNotSet
	}

	if s.operator == nil || !s.operator.IsInitialized() {
		return errOperatorNotInit
	}

	// Ensure parent directory exists
	configDir := filepath.Dir(s.operatorConfigPath)
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("failed to create operator config directory: %w", err)
	}

	// Create resolver directory
	if s.resolverBasePath != "" {
		if err := os.MkdirAll(s.resolverBasePath, 0755); err != nil {
			return fmt.Errorf("failed to create resolver directory: %w", err)
		}
	}

	// Build operator.conf content
	operatorJWT := s.operator.JWT()
	systemAccountPubKey := s.operator.SystemAccountPublicKey()

	var config string
	if operatorJWT != "" {
		config = fmt.Sprintf(`# NATS Operator Configuration (auto-generated by datasvc)
# This file is included by nats-server.conf to enable JWT-based multi-tenancy

# Operator JWT (inline)
operator: %s

`, operatorJWT)
	}

	if systemAccountPubKey != "" {
		config += fmt.Sprintf(`# System account for $SYS subject access
system_account: %s

`, systemAccountPubKey)
	}

	if s.resolverBasePath != "" {
		config += fmt.Sprintf(`# Full resolver for account JWT storage
resolver: {
  type: full
  dir: "%s"
  allow_delete: true
  interval: "2m"
}
`, s.resolverBasePath)
	}

	// Write the config file
	if err := os.WriteFile(s.operatorConfigPath, []byte(config), 0644); err != nil {
		return fmt.Errorf("failed to write operator config: %w", err)
	}

	log.Printf("Wrote operator config to %s", s.operatorConfigPath)

	// If we have a system account JWT, write it to the resolver
	if s.resolverBasePath != "" && systemAccountPubKey != "" {
		systemJWT := s.operator.SystemAccountJWT()
		if systemJWT != "" {
			jwtPath := filepath.Join(s.resolverBasePath, systemAccountPubKey+".jwt")
			if err := os.WriteFile(jwtPath, []byte(systemJWT), 0644); err != nil {
				return fmt.Errorf("failed to write system account JWT: %w", err)
			}
			log.Printf("Wrote system account JWT to %s", jwtPath)
		}
	}

	return nil
}

// WriteAccountJWT writes an account JWT to the file-based resolver directory.
// This allows the NATS server to pick up new accounts without restart.
func (s *NATSAccountServer) WriteAccountJWT(accountPublicKey, accountJWT string) error {
	s.mu.RLock()
	resolverPath := s.resolverBasePath
	s.mu.RUnlock()

	if resolverPath == "" {
		return errResolverPathNotSet
	}

	if accountPublicKey == "" || accountJWT == "" {
		return errAccountKeyJWTRequired
	}

	// Ensure resolver directory exists
	if err := os.MkdirAll(resolverPath, 0755); err != nil {
		return fmt.Errorf("failed to create resolver directory: %w", err)
	}

	// Write the JWT file
	jwtPath := filepath.Join(resolverPath, accountPublicKey+".jwt")
	if err := os.WriteFile(jwtPath, []byte(accountJWT), 0644); err != nil {
		return fmt.Errorf("failed to write account JWT: %w", err)
	}

	log.Printf("Wrote account JWT to %s", jwtPath)
	return nil
}

// BootstrapOperator initializes the NATS operator for the platform.
// This can either generate a new operator key pair or import an existing seed.
// Should be called once during initial platform setup.
func (s *NATSAccountServer) BootstrapOperator(
	ctx context.Context,
	req *proto.BootstrapOperatorRequest,
) (*proto.BootstrapOperatorResponse, error) {
	if err := s.authorizeRequest(ctx); err != nil {
		return nil, err
	}

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

	// Store original state for rollback on failure
	originalOperator := s.operator
	originalSigner := s.signer
	originalSystemAccountSeed := s.systemAccountSeed

	// Update the server state
	s.operator = operator
	s.signer = accounts.NewAccountSigner(operator)

	// Store system account seed for JWT push operations
	if result.SystemAccountSeed != "" {
		s.systemAccountSeed = result.SystemAccountSeed
	}

	// Write operator config for NATS resolver (if paths are configured)
	if s.operatorConfigPath != "" {
		if err := s.writeOperatorConfigLocked(); err != nil {
			// Rollback state on failure to maintain consistency
			s.operator = originalOperator
			s.signer = originalSigner
			s.systemAccountSeed = originalSystemAccountSeed
			return nil, status.Errorf(codes.Internal, "failed to write operator config: %v", err)
		}
	}

	return &proto.BootstrapOperatorResponse{
		OperatorPublicKey:      result.OperatorPublicKey,
		OperatorSeed:           result.OperatorSeed, // Only set if newly generated
		OperatorJwt:            result.OperatorJWT,
		SystemAccountPublicKey: result.SystemAccountPublicKey,
		SystemAccountSeed:      result.SystemAccountSeed,
		SystemAccountJwt:       result.SystemAccountJWT,
	}, nil
}

// writeOperatorConfigLocked writes the operator config without acquiring locks.
// Must be called with s.mu held.
func (s *NATSAccountServer) writeOperatorConfigLocked() error {
	if s.operatorConfigPath == "" {
		return errOperatorConfigNotSet
	}

	if s.operator == nil || !s.operator.IsInitialized() {
		return errOperatorNotInit
	}

	// Ensure parent directory exists
	configDir := filepath.Dir(s.operatorConfigPath)
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("failed to create operator config directory: %w", err)
	}

	// Create resolver directory
	if s.resolverBasePath != "" {
		if err := os.MkdirAll(s.resolverBasePath, 0755); err != nil {
			return fmt.Errorf("failed to create resolver directory: %w", err)
		}
	}

	// Build operator.conf content
	operatorJWT := s.operator.JWT()
	systemAccountPubKey := s.operator.SystemAccountPublicKey()

	var config string
	if operatorJWT != "" {
		config = fmt.Sprintf(`# NATS Operator Configuration (auto-generated by datasvc)
# This file is included by nats-server.conf to enable JWT-based multi-tenancy

# Operator JWT (inline)
operator: %s

`, operatorJWT)
	}

	if systemAccountPubKey != "" {
		config += fmt.Sprintf(`# System account for $SYS subject access
system_account: %s

`, systemAccountPubKey)
	}

	if s.resolverBasePath != "" {
		config += fmt.Sprintf(`# Full resolver for account JWT storage
resolver: {
  type: full
  dir: "%s"
  allow_delete: true
  interval: "2m"
}
`, s.resolverBasePath)
	}

	// Write the config file
	if err := os.WriteFile(s.operatorConfigPath, []byte(config), 0644); err != nil {
		return fmt.Errorf("failed to write operator config: %w", err)
	}

	log.Printf("Wrote operator config to %s", s.operatorConfigPath)

	// If we have a system account JWT, write it to the resolver
	if s.resolverBasePath != "" && systemAccountPubKey != "" {
		systemJWT := s.operator.SystemAccountJWT()
		if systemJWT != "" {
			jwtPath := filepath.Join(s.resolverBasePath, systemAccountPubKey+".jwt")
			if err := os.WriteFile(jwtPath, []byte(systemJWT), 0644); err != nil {
				return fmt.Errorf("failed to write system account JWT: %w", err)
			}
			log.Printf("Wrote system account JWT to %s", jwtPath)
		}
	}

	return nil
}

// GetOperatorInfo returns the current operator status and public key.
// Used to verify the operator is initialized before tenant operations.
func (s *NATSAccountServer) GetOperatorInfo(
	ctx context.Context,
	_ *proto.GetOperatorInfoRequest,
) (*proto.GetOperatorInfoResponse, error) {
	if err := s.authorizeRequest(ctx); err != nil {
		return nil, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.operator == nil || !s.operator.IsInitialized() {
		return &proto.GetOperatorInfoResponse{
			IsInitialized: false,
		}, nil
	}

	return &proto.GetOperatorInfoResponse{
		OperatorPublicKey:      s.operator.PublicKey(),
		OperatorName:           s.operator.Name(),
		IsInitialized:          true,
		SystemAccountPublicKey: s.operator.SystemAccountPublicKey(),
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
	ctx context.Context,
	req *proto.CreateTenantAccountRequest,
) (*proto.CreateTenantAccountResponse, error) {
	if err := s.authorizeRequest(ctx); err != nil {
		return nil, err
	}

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
	protoMappings := req.GetSubjectMappings()
	mappings := make([]accounts.SubjectMapping, 0, len(protoMappings))
	for _, m := range protoMappings {
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
	ctx context.Context,
	req *proto.GenerateUserCredentialsRequest,
) (*proto.GenerateUserCredentialsResponse, error) {
	if err := s.authorizeRequest(ctx); err != nil {
		return nil, err
	}

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
	ctx context.Context,
	req *proto.SignAccountJWTRequest,
) (*proto.SignAccountJWTResponse, error) {
	if err := s.authorizeRequest(ctx); err != nil {
		return nil, err
	}

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
	protoMappings := req.GetSubjectMappings()
	mappings := make([]accounts.SubjectMapping, 0, len(protoMappings))
	for _, m := range protoMappings {
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
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_UNSPECIFIED:
		return accounts.CredentialTypeCollector
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_COLLECTOR:
		return accounts.CredentialTypeCollector
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_SERVICE:
		return accounts.CredentialTypeService
	case proto.UserCredentialType_USER_CREDENTIAL_TYPE_ADMIN:
		return accounts.CredentialTypeAdmin
	}
	return accounts.CredentialTypeCollector
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

// PushAccountJWT pushes an account JWT to the NATS resolver via $SYS.
// This makes the account immediately available without NATS restart.
func (s *NATSAccountServer) PushAccountJWT(
	ctx context.Context,
	req *proto.PushAccountJWTRequest,
) (*proto.PushAccountJWTResponse, error) {
	if err := s.authorizeRequest(ctx); err != nil {
		return nil, err
	}

	if req.GetAccountPublicKey() == "" {
		return nil, status.Error(codes.InvalidArgument, "account_public_key is required")
	}
	if req.GetAccountJwt() == "" {
		return nil, status.Error(codes.InvalidArgument, "account_jwt is required")
	}

	conn, err := s.getResolverConn()
	if err != nil {
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: "resolver connection not available: " + err.Error(),
		}, nil
	}

	subject := fmt.Sprintf("$SYS.REQ.ACCOUNT.%s.CLAIMS.UPDATE", req.GetAccountPublicKey())
	resp, err := conn.Request(subject, []byte(req.GetAccountJwt()), 5*time.Second)
	if err != nil {
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: "failed to push JWT to resolver: " + err.Error(),
		}, nil
	}

	if len(resp.Data) == 0 {
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: "resolver response was empty",
		}, nil
	}

	var updateResp claimUpdateResponse
	if err := json.Unmarshal(resp.Data, &updateResp); err != nil {
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: "failed to parse resolver response: " + err.Error(),
		}, nil
	}

	if updateResp.Error != nil {
		return &proto.PushAccountJWTResponse{
			Success: false,
			Message: updateResp.Error.Description,
		}, nil
	}

	message := "JWT pushed to resolver successfully"
	if updateResp.Data != nil && updateResp.Data.Message != "" {
		message = updateResp.Data.Message
	}

	return &proto.PushAccountJWTResponse{
		Success: true,
		Message: message,
	}, nil
}

type claimUpdateResponse struct {
	Data  *claimUpdateStatus `json:"data,omitempty"`
	Error *claimUpdateError  `json:"error,omitempty"`
}

type claimUpdateStatus struct {
	Account string `json:"account,omitempty"`
	Code    int    `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

type claimUpdateError struct {
	Account     string `json:"account,omitempty"`
	Code        int    `json:"code"`
	Description string `json:"description,omitempty"`
}
