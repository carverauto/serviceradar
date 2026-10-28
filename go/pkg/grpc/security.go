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

package grpc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	SecurityModeNone models.SecurityMode = "none"
	SecurityModeMTLS models.SecurityMode = "mtls"
)

// NoSecurityProvider implements SecurityProvider with no security (development only).
type NoSecurityProvider struct {
	logger logger.Logger
}

func (*NoSecurityProvider) GetClientCredentials(context.Context) (grpc.DialOption, error) {
	return grpc.WithTransportCredentials(insecure.NewCredentials()), nil
}

func (*NoSecurityProvider) GetServerCredentials(context.Context) (grpc.ServerOption, error) {
	return grpc.Creds(insecure.NewCredentials()), nil
}

func (*NoSecurityProvider) Close() error {
	return nil
}

// MTLSProvider implements SecurityProvider with mutual TLS.
type MTLSProvider struct {
	config      *models.SecurityConfig
	clientCreds credentials.TransportCredentials
	serverCreds credentials.TransportCredentials
	closeOnce   sync.Once
	needsClient bool
	needsServer bool
	logger      logger.Logger
}

// NewMTLSProvider creates a new MTLSProvider with the given configuration.
func NewMTLSProvider(config *models.SecurityConfig, log logger.Logger) (*MTLSProvider, error) {
	if config == nil {
		return nil, errSecurityConfigRequired
	}

	if config.TLS.CertFile == "" || config.TLS.KeyFile == "" || config.TLS.CAFile == "" {
		log.Error().Msg("ERROR: mTLS mode requires tls.cert_file, tls.key_file, and tls.ca_file to be set in the security config.")

		return nil, fmt.Errorf("%w: missing required TLS file paths in config", errSecurityConfigRequired)
	}

	provider := &MTLSProvider{config: config, logger: log}
	if err := provider.setCredentialNeeds(); err != nil {
		return nil, err
	}

	log.Info().
		Str("role", string(config.Role)).
		Bool("needsClient", provider.needsClient).
		Bool("needsServer", provider.needsServer).
		Msg("Initializing mTLS provider")

	if err := provider.loadCredentials(); err != nil {
		return nil, err
	}

	return provider, nil
}

// setCredentialNeeds determines which TLS credentials are required based on the role.
func (p *MTLSProvider) setCredentialNeeds() error {
	roleNeeds := map[models.ServiceRole]struct {
		needsClient, needsServer bool
	}{
		models.RoleGateway:     {true, true}, // Client to Agent/Core, Server for health
		models.RoleAgent:       {true, true}, // Client to checkers, Server for Gateway
		models.RoleCore:        {true, true}, // Core now dials external services (KV/DataSvc) and serves RPCs
		models.RoleKVStore:     {true, true}, // Client to NATS, Server for gRPC
		models.RoleDataService: {true, true}, // Client to NATS, Server for gRPC
		models.RoleChecker:     {true, true}, // Client to KV/telemetry, Server for Gateway/Agent
		models.RoleSync:        {true, true}, // Client to gateway, optional server for health
	}

	needs, ok := roleNeeds[p.config.Role]
	if !ok {
		return fmt.Errorf("%w: %s", errInvalidServiceRole, p.config.Role)
	}

	p.needsClient = needs.needsClient
	p.needsServer = needs.needsServer

	return nil
}

// loadCredentials loads the necessary TLS credentials based on role needs.
func (p *MTLSProvider) loadCredentials() error {
	var err error

	if p.needsClient {
		p.logger.Info().Msg("Loading client credentials using paths from config.TLS")

		p.clientCreds, err = loadClientCredentials(p.config, p.logger)
		if err != nil {
			return fmt.Errorf("%w: %w", errFailedToLoadClientCreds, err)
		}
	}

	if p.needsServer {
		p.logger.Info().Msg("Loading server credentials using paths from config.TLS")

		p.serverCreds, err = loadServerCredentials(p.config, p.logger)
		if err != nil {
			return fmt.Errorf("%w: %w", errFailedToLoadServerCreds, err)
		}
	}

	return nil
}

func (p *MTLSProvider) Close() error {
	var err error

	p.closeOnce.Do(func() {
		// No resources to cleanup in current implementation
	})

	return err
}

// loadClientCredentials loads client TLS credentials using paths from config.TLS.
func loadClientCredentials(config *models.SecurityConfig, log logger.Logger) (credentials.TransportCredentials, error) {
	// Normalize paths with CertDir if they are relative
	certPath := config.TLS.CertFile
	keyPath := config.TLS.KeyFile
	caPath := config.TLS.CAFile

	if !filepath.IsAbs(certPath) && config.CertDir != "" {
		certPath = filepath.Join(config.CertDir, certPath)
	}

	if !filepath.IsAbs(keyPath) && config.CertDir != "" {
		keyPath = filepath.Join(config.CertDir, keyPath)
	}

	if !filepath.IsAbs(caPath) && config.CertDir != "" {
		caPath = filepath.Join(config.CertDir, caPath)
	}

	log.Info().
		Str("certPath", certPath).
		Str("keyPath", keyPath).
		Str("caPath", caPath).
		Msg("Loading client certificate")

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToLoadClientCert, err)
	}

	caCert, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadCACert, err)
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: failed to parse CA certificate from %s", errFailedToAppendCACert, caPath)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caPool,
		ServerName:   config.ServerName, // Use server name from config if needed for verification
		MinVersion:   tls.VersionTLS13,
	}

	return credentials.NewTLS(tlsConfig), nil
}

func loadServerCredentials(config *models.SecurityConfig, log logger.Logger) (credentials.TransportCredentials, error) {
	certPath, keyPath, clientCaPath := normalizePaths(config, log)

	cert, err := loadServerCert(certPath, keyPath, log)
	if err != nil {
		return nil, err
	}

	clientCaPool, err := loadClientCAPool(clientCaPath, log)
	if err != nil {
		return nil, err
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    clientCaPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}

	return credentials.NewTLS(tlsConfig), nil
}

// normalizePaths resolves certificate paths based on config.
func normalizePaths(config *models.SecurityConfig, log logger.Logger) (certPath, keyPath, clientCaPath string) {
	certPath = config.TLS.CertFile
	keyPath = config.TLS.KeyFile
	clientCaPath = config.TLS.ClientCAFile

	if !filepath.IsAbs(certPath) && config.CertDir != "" {
		certPath = filepath.Join(config.CertDir, certPath)
	}

	if !filepath.IsAbs(keyPath) && config.CertDir != "" {
		keyPath = filepath.Join(config.CertDir, keyPath)
	}

	if clientCaPath == "" {
		log.Info().Str("caFile", config.TLS.CAFile).Msg("ClientCAFile not specified, using CAFile for client verification")

		clientCaPath = config.TLS.CAFile
		if clientCaPath != "" && !filepath.IsAbs(clientCaPath) && config.CertDir != "" {
			clientCaPath = filepath.Join(config.CertDir, clientCaPath)
		}
	} else if !filepath.IsAbs(clientCaPath) && config.CertDir != "" {
		clientCaPath = filepath.Join(config.CertDir, clientCaPath)

		log.Info().Str("clientCAFile", clientCaPath).Msg("Normalized ClientCAFile")
	}

	return certPath, keyPath, clientCaPath
}

// loadServerCert loads the server certificate and key pair.
func loadServerCert(certPath, keyPath string, log logger.Logger) (tls.Certificate, error) {
	log.Info().Str("certPath", certPath).Str("keyPath", keyPath).Msg("Loading server certificate")

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("%w: %w", errFailedToLoadServerCert, err)
	}

	return cert, nil
}

// loadClientCAPool loads and parses the client CA certificate into a pool.
func loadClientCAPool(clientCaPath string, log logger.Logger) (*x509.CertPool, error) {
	log.Info().Str("clientCaPath", clientCaPath).Msg("Loading server Client CA certificate")

	clientCaCert, err := os.ReadFile(clientCaPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadClientCACert, err)
	}

	clientCaPool := x509.NewCertPool()
	if !clientCaPool.AppendCertsFromPEM(clientCaCert) {
		return nil, fmt.Errorf("%w: failed to parse Client CA certificate from %s", errFailedToAppendClientCACert, clientCaPath)
	}

	return clientCaPool, nil
}

func (p *MTLSProvider) GetClientCredentials(_ context.Context) (grpc.DialOption, error) {
	if !p.needsClient {
		return nil, errServiceNotClient
	}

	return grpc.WithTransportCredentials(p.clientCreds), nil
}

func (p *MTLSProvider) GetServerCredentials(_ context.Context) (grpc.ServerOption, error) {
	if !p.needsServer {
		return nil, errServiceNotServer
	}

	return grpc.Creds(p.serverCreds), nil
}

// NewSecurityProvider creates the appropriate security provider based on mode.
func NewSecurityProvider(_ context.Context, config *models.SecurityConfig, log logger.Logger) (SecurityProvider, error) {
	if config == nil {
		log.Error().Msg("ERROR: No security config provided")
		return nil, errSecurityConfigRequired
	}

	// Defensive check: ensure mode is a non-empty string
	if config.Mode == "" {
		log.Error().Msg("ERROR: Empty security mode")
		return nil, errSecurityConfigRequired
	}

	log.Info().Str("mode", string(config.Mode)).Msg("Creating security provider")

	// Make sure we're comparing case-insensitive strings
	mode := strings.ToLower(string(config.Mode))

	switch models.SecurityMode(mode) {
	case SecurityModeNone:
		log.Info().Msg("Using no security (explicitly configured)")

		return &NoSecurityProvider{logger: log}, nil
	case SecurityModeMTLS:
		log.Info().Str("certDir", config.CertDir).Msg("Initializing mTLS security provider")

		provider, err := NewMTLSProvider(config, log)
		if err != nil {
			// Log detailed error information for debugging
			log.Error().Err(err).Msg("ERROR creating mTLS provider")

			return nil, fmt.Errorf("%w: %w", errFailedToCreateMTLSProvider, err)
		}

		log.Info().Msg("Successfully created mTLS security provider")

		return provider, nil
	default:
		log.Error().Str("mode", string(config.Mode)).Msg("ERROR: Unknown security mode")

		return nil, fmt.Errorf("%w: %s (see https://docs.serviceradar.cloud/docs/migrating-off-spire)", errUnknownSecurityMode, config.Mode)
	}
}
