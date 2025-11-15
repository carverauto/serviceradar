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

package db

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// NewCNPGPool dials the configured CNPG cluster and returns a pgx pool that can
// be used for Timescale-backed reads/writes.
func NewCNPGPool(ctx context.Context, cfg *models.CNPGDatabase, log logger.Logger) (*pgxpool.Pool, error) {
	if cfg == nil {
		return nil, nil
	}

	cnpg := *cfg
	if cnpg.Port == 0 {
		cnpg.Port = 5432
	}

	connURL := url.URL{
		Scheme: "postgres",
		Host:   fmt.Sprintf("%s:%d", cnpg.Host, cnpg.Port),
		Path:   "/" + cnpg.Database,
	}

	if cnpg.Username != "" {
		if cnpg.Password != "" {
			connURL.User = url.UserPassword(cnpg.Username, cnpg.Password)
		} else {
			connURL.User = url.User(cnpg.Username)
		}
	}

	query := connURL.Query()

	sslMode := cnpg.SSLMode
	if sslMode == "" {
		sslMode = "disable"
	}
	query.Set("sslmode", sslMode)

	if cnpg.ApplicationName != "" {
		query.Set("application_name", cnpg.ApplicationName)
	}

	for k, v := range cnpg.ExtraRuntimeParams {
		if k == "" {
			continue
		}

		query.Set(k, v)
	}

	connURL.RawQuery = query.Encode()

	poolConfig, err := pgxpool.ParseConfig(connURL.String())
	if err != nil {
		return nil, fmt.Errorf("cnpg: failed to parse connection string: %w", err)
	}

	if cnpg.MaxConnections > 0 {
		poolConfig.MaxConns = cnpg.MaxConnections
	}

	if cnpg.MinConnections > 0 {
		poolConfig.MinConns = cnpg.MinConnections
	}

	if cnpg.MaxConnLifetime > 0 {
		poolConfig.MaxConnLifetime = time.Duration(cnpg.MaxConnLifetime)
	}

	if cnpg.HealthCheckPeriod > 0 {
		poolConfig.HealthCheckPeriod = time.Duration(cnpg.HealthCheckPeriod)
	}

	if poolConfig.ConnConfig.RuntimeParams == nil {
		poolConfig.ConnConfig.RuntimeParams = make(map[string]string)
	}

	for k, v := range cnpg.ExtraRuntimeParams {
		if k == "" {
			continue
		}

		poolConfig.ConnConfig.RuntimeParams[k] = v
	}

	if cnpg.StatementTimeout > 0 {
		timeout := time.Duration(cnpg.StatementTimeout) / time.Millisecond
		poolConfig.ConnConfig.RuntimeParams["statement_timeout"] = fmt.Sprintf("%d", timeout)
	}

	if tlsConfig, err := buildCNPGTLSConfig(&cnpg); err != nil {
		return nil, err
	} else if tlsConfig != nil {
		poolConfig.ConnConfig.TLSConfig = tlsConfig
	}

	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("cnpg: failed to initialize pool: %w", err)
	}

	if log != nil {
		log.Info().
			Str("host", cnpg.Host).
			Int("port", cnpg.Port).
			Int32("max_conns", poolConfig.MaxConns).
			Msg("connected to CNPG/Timescale cluster")
	}

	return pool, nil
}

func newCNPGPool(ctx context.Context, config *models.CoreServiceConfig, log logger.Logger) (*pgxpool.Pool, error) {
	if config == nil || config.CNPG == nil {
		return nil, nil
	}

	return NewCNPGPool(ctx, config.CNPG, log)
}

func buildCNPGTLSConfig(cfg *models.CNPGDatabase) (*tls.Config, error) {
	if cfg == nil || cfg.TLS == nil {
		return nil, nil
	}

	resolve := func(path string) string {
		if path == "" {
			return path
		}

		if filepath.IsAbs(path) || cfg.CertDir == "" {
			return path
		}

		return filepath.Join(cfg.CertDir, path)
	}

	certFile := resolve(cfg.TLS.CertFile)
	keyFile := resolve(cfg.TLS.KeyFile)
	caFile := resolve(cfg.TLS.CAFile)

	if certFile == "" || keyFile == "" || caFile == "" {
		return nil, fmt.Errorf("cnpg tls: cert_file, key_file, and ca_file are required")
	}

	clientCert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("cnpg tls: failed to load client keypair: %w", err)
	}

	caBytes, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("cnpg tls: failed to read CA file: %w", err)
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caBytes) {
		return nil, fmt.Errorf("cnpg tls: unable to append CA certificate")
	}

	return &tls.Config{
		Certificates: []tls.Certificate{clientCert},
		RootCAs:      caPool,
		MinVersion:   tls.VersionTLS12,
		ServerName:   cfg.Host,
	}, nil
}
