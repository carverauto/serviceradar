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

package logger

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	log "go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/log/global"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.31.0"
	"google.golang.org/grpc/credentials"
)

// Static errors for err113 compliance
var (
	ErrOTelLoggingDisabled  = errors.New("OTel logging is disabled")
	ErrOTelEndpointRequired = errors.New("OTel endpoint is required when enabled")
)

type OTelWriter struct {
	provider *sdklog.LoggerProvider
	loggers  map[string]log.Logger
	mu       sync.Mutex
	ctx      context.Context
}

type OTelConfig struct {
	Enabled      bool              `json:"enabled" yaml:"enabled"`
	Endpoint     string            `json:"endpoint" yaml:"endpoint"`
	Headers      map[string]string `json:"headers" yaml:"headers"`
	ServiceName  string            `json:"service_name" yaml:"service_name"`
	BatchTimeout Duration          `json:"batch_timeout" yaml:"batch_timeout"`
	Insecure     bool              `json:"insecure" yaml:"insecure"`
	TLS          *TLSConfig        `json:"tls,omitempty" yaml:"tls,omitempty"`
}

type TLSConfig struct {
	CertFile string `json:"cert_file" yaml:"cert_file"`
	KeyFile  string `json:"key_file" yaml:"key_file"`
	CAFile   string `json:"ca_file,omitempty" yaml:"ca_file,omitempty"`
}

// otelProvider is managed internally for shutdown
//
//nolint:gochecknoglobals // needed for proper OTel shutdown handling
var otelProvider *sdklog.LoggerProvider

func NewOTELWriter(ctx context.Context, config OTelConfig) (*OTelWriter, error) {
	if !config.Enabled {
		return nil, ErrOTelLoggingDisabled
	}

	if config.Endpoint == "" {
		return nil, ErrOTelEndpointRequired
	}

	opts := []otlploggrpc.Option{
		otlploggrpc.WithEndpoint(config.Endpoint),
	}

	if config.Insecure {
		opts = append(opts, otlploggrpc.WithInsecure())
	} else if config.TLS != nil {
		tlsConfig, err := setupTLSConfig(config.TLS)
		if err != nil {
			return nil, fmt.Errorf("failed to setup TLS configuration: %w", err)
		}

		creds := credentials.NewTLS(tlsConfig)
		opts = append(opts, otlploggrpc.WithTLSCredentials(creds))
	}

	if len(config.Headers) > 0 {
		opts = append(opts, otlploggrpc.WithHeaders(config.Headers))
	}

	exporter, err := otlploggrpc.New(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to create OTLP log exporter: %w", err)
	}

	serviceName := config.ServiceName
	if serviceName == "" {
		serviceName = "serviceradar"
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion("1.0.0"),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	batchTimeout := time.Duration(config.BatchTimeout)
	if batchTimeout == 0 {
		batchTimeout = 5 * time.Second
	}

	processorOptions := []sdklog.BatchProcessorOption{
		sdklog.WithExportTimeout(batchTimeout),
	}

	processor := sdklog.NewBatchProcessor(exporter, processorOptions...)

	provider := sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(processor),
	)

	otelProvider = provider
	global.SetLoggerProvider(provider)

	// Return the initialized writer struct, DO NOT create a single logger here.
	return &OTelWriter{
		provider: provider,
		loggers:  make(map[string]log.Logger),
		ctx:      ctx,
	}, nil
}

func (w *OTelWriter) Write(p []byte) (n int, err error) {
	if w.provider == nil {
		return len(p), nil
	}

	logEntry := make(map[string]interface{})
	if err := json.Unmarshal(p, &logEntry); err != nil {
		return len(p), nil
	}

	record := log.Record{}

	if timestamp, ok := logEntry["time"].(string); ok {
		if parsedTime, err := time.Parse(time.RFC3339, timestamp); err == nil {
			record.SetTimestamp(parsedTime)
		}
	}

	if !record.Timestamp().IsZero() {
		delete(logEntry, "time")
	}

	if levelStr, ok := logEntry["level"].(string); ok {
		record.SetSeverity(mapZerologLevelToOTEL(levelStr))
		record.SetSeverityText(levelStr)
		delete(logEntry, "level")
	}

	if message, ok := logEntry["message"].(string); ok {
		record.SetBody(log.StringValue(message))
		delete(logEntry, "message")
	}

	// Process Trace and Span IDs as regular attributes
	// The OTel Log Record doesn't have SetTraceID/SetSpanID methods
	// So we'll keep these as regular attributes that observability backends can correlate

	// Select Dynamic Logger Scope
	componentName := "serviceradar-logger" // Default scope
	if component, ok := logEntry["component"].(string); ok && component != "" {
		componentName = component

		delete(logEntry, "component")
	}

	w.mu.Lock()
	logger, found := w.loggers[componentName]

	if !found {
		logger = w.provider.Logger(componentName)
		w.loggers[componentName] = logger
	}

	w.mu.Unlock()

	// Add all remaining fields as attributes.
	for key, value := range logEntry {
		record.AddAttributes(log.String(key, fmt.Sprintf("%v", value)))
	}

	logger.Emit(w.ctx, record)

	return len(p), nil
}

// func mapZerologLevelToOTEL(level string) log.Severity {
func mapZerologLevelToOTEL(level string) log.Severity {
	switch strings.ToLower(level) {
	case "trace":
		return log.SeverityTrace
	case "debug":
		return log.SeverityDebug
	case "info":
		return log.SeverityInfo
	case "warn", "warning":
		return log.SeverityWarn
	case "error":
		return log.SeverityError
	case "fatal":
		return log.SeverityFatal
	case "panic":
		return log.SeverityFatal
	default:
		return log.SeverityInfo
	}
}

func ShutdownOTEL() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var firstErr error

	if otelProvider != nil {
		if err := otelProvider.Shutdown(ctx); err != nil && firstErr == nil {
			firstErr = err
		}
		otelProvider = nil
	}

	if err := shutdownMeterProvider(ctx); err != nil && firstErr == nil {
		firstErr = err
	}

	return firstErr
}

func setupTLSConfig(tlsConfig *TLSConfig) (*tls.Config, error) {
	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	if tlsConfig.CertFile != "" && tlsConfig.KeyFile != "" {
		cert, err := tls.LoadX509KeyPair(tlsConfig.CertFile, tlsConfig.KeyFile)
		if err != nil {
			return nil, fmt.Errorf("failed to load client certificate: %w", err)
		}

		config.Certificates = []tls.Certificate{cert}
	}

	if tlsConfig.CAFile != "" {
		caCert, err := os.ReadFile(tlsConfig.CAFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read CA certificate: %w", err)
		}

		caCertPool := x509.NewCertPool()
		if !caCertPool.AppendCertsFromPEM(caCert) {
			return nil, errFailedToParseCACert
		}

		config.RootCAs = caCertPool
	}

	return config, nil
}

type MultiWriter struct {
	writers []io.Writer
}

func NewMultiWriter(writers ...io.Writer) *MultiWriter {
	return &MultiWriter{writers: writers}
}

func (mw *MultiWriter) Write(p []byte) (n int, err error) {
	for _, w := range mw.writers {
		n, err = w.Write(p)
		if err != nil {
			return n, err
		}

		if n != len(p) {
			err = io.ErrShortWrite
			return n, err
		}
	}

	return len(p), nil
}
