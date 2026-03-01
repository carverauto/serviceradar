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
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

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

const (
	maxAttributeValueLength   = 4096
	maxStructuredPreviewCount = 5
	maxPreviewElementLength   = 64
	truncatedKeysAttribute    = "otel.truncated_keys"
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
	sanitized, truncatedKeys := sanitizeLogEntry(logEntry)
	for key, value := range sanitized {
		record.AddAttributes(log.String(key, value))
	}

	if len(truncatedKeys) > 0 {
		record.AddAttributes(log.String(truncatedKeysAttribute, strings.Join(truncatedKeys, ",")))
	}

	logger.Emit(w.ctx, record)

	return len(p), nil
}

func sanitizeLogEntry(logEntry map[string]interface{}) (map[string]string, []string) {
	sanitized := make(map[string]string, len(logEntry))
	truncated := make([]string, 0, len(logEntry))

	for key, value := range logEntry {
		formatted, wasTruncated := formatAttributeValue(value)
		sanitized[key] = formatted

		if wasTruncated {
			truncated = append(truncated, key)
		}
	}

	sort.Strings(truncated)
	return sanitized, truncated
}

func formatAttributeValue(value interface{}) (string, bool) {
	switch v := value.(type) {
	case nil:
		return "null", false
	case string:
		return truncateString(v, maxAttributeValueLength)
	case bool:
		return fmt.Sprintf("%t", v), false
	case float64, float32,
		int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64:
		return fmt.Sprintf("%v", v), false
	case json.Number:
		return v.String(), false
	case []byte:
		return fmt.Sprintf("<bytes len=%d>", len(v)), len(v) > maxPreviewElementLength
	case []interface{}:
		return summarizeSlice(v)
	case map[string]interface{}:
		return summarizeMap(v)
	default:
		if stringer, ok := value.(fmt.Stringer); ok {
			return truncateString(stringer.String(), maxAttributeValueLength)
		}

		if marshaled, err := json.Marshal(value); err == nil {
			return truncateString(string(marshaled), maxAttributeValueLength)
		}

		return truncateString(fmt.Sprintf("%v", value), maxAttributeValueLength)
	}
}

func summarizeSlice(items []interface{}) (string, bool) {
	length := len(items)
	if length == 0 {
		return "[]", false
	}

	if length <= maxStructuredPreviewCount {
		if payload, err := json.Marshal(items); err == nil {
			return truncateString(string(payload), maxAttributeValueLength)
		}
	}

	previewCount := maxStructuredPreviewCount
	if length < previewCount {
		previewCount = length
	}

	previews := make([]string, 0, previewCount)
	for i := 0; i < previewCount; i++ {
		previews = append(previews, previewString(items[i]))
	}

	builder := strings.Builder{}
	builder.Grow(maxAttributeValueLength)
	builder.WriteString("[")
	builder.WriteString(strings.Join(previews, ", "))
	if length > previewCount {
		builder.WriteString(", ...")
	}
	builder.WriteString("] (total=")
	builder.WriteString(fmt.Sprintf("%d", length))
	builder.WriteString(", truncated)")

	result, _ := truncateString(builder.String(), maxAttributeValueLength)
	return result, true
}

func summarizeMap(values map[string]interface{}) (string, bool) {
	totalKeys := len(values)
	if totalKeys == 0 {
		return "{}", false
	}

	if totalKeys <= maxStructuredPreviewCount {
		if payload, err := json.Marshal(values); err == nil {
			return truncateString(string(payload), maxAttributeValueLength)
		}
	}

	preview := make([]string, 0, maxStructuredPreviewCount)
	for key := range values {
		preview = append(preview, key)
		if len(preview) == maxStructuredPreviewCount {
			break
		}
	}

	builder := strings.Builder{}
	builder.Grow(maxAttributeValueLength)
	builder.WriteString("{keys=")
	builder.WriteString(fmt.Sprintf("%d", totalKeys))
	if len(preview) > 0 {
		builder.WriteString(", sample=[")
		builder.WriteString(strings.Join(preview, ", "))
		if totalKeys > len(preview) {
			builder.WriteString(", ...")
		}
		builder.WriteString("]")
	}
	builder.WriteString(", truncated}")

	result, _ := truncateString(builder.String(), maxAttributeValueLength)
	return result, true
}

func previewString(value interface{}) string {
	switch v := value.(type) {
	case string:
		truncated, _ := truncateString(v, maxPreviewElementLength)
		return fmt.Sprintf("%q", truncated)
	case map[string]interface{}:
		return fmt.Sprintf("map(len=%d)", len(v))
	case []interface{}:
		return fmt.Sprintf("slice(len=%d)", len(v))
	default:
		truncated, _ := truncateString(fmt.Sprintf("%v", v), maxPreviewElementLength)
		return truncated
	}
}

func truncateString(value string, limit int) (string, bool) {
	if len(value) <= limit {
		return value, false
	}

	if limit <= 3 {
		truncated := value[:limit]
		for !utf8.ValidString(truncated) && len(truncated) > 0 {
			truncated = truncated[:len(truncated)-1]
		}
		return truncated, true
	}

	truncated := value[:limit-3]
	for !utf8.ValidString(truncated) && len(truncated) > 0 {
		truncated = truncated[:len(truncated)-1]
	}

	return truncated + "...", true
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
