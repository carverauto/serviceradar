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
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/log/global"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.31.0"
)

type OTelWriter struct {
	logger log.Logger
	ctx    context.Context
}

type OTelConfig struct {
	Enabled      bool              `json:"enabled" yaml:"enabled"`
	Endpoint     string            `json:"endpoint" yaml:"endpoint"`
	Headers      map[string]string `json:"headers" yaml:"headers"`
	ServiceName  string            `json:"service_name" yaml:"service_name"`
	BatchTimeout time.Duration     `json:"batch_timeout" yaml:"batch_timeout"`
	Insecure     bool              `json:"insecure" yaml:"insecure"`
}

var otelProvider *sdklog.LoggerProvider

func NewOTelWriter(config OTelConfig) (*OTelWriter, error) {
	if !config.Enabled {
		return nil, fmt.Errorf("OTel logging is disabled")
	}
	
	if config.Endpoint == "" {
		return nil, fmt.Errorf("OTel endpoint is required when enabled")
	}

	ctx := context.Background()

	opts := []otlploggrpc.Option{
		otlploggrpc.WithEndpoint(config.Endpoint),
	}

	if config.Insecure {
		opts = append(opts, otlploggrpc.WithInsecure())
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

	batchTimeout := config.BatchTimeout
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

	logger := provider.Logger("serviceradar-logger")

	return &OTelWriter{
		logger: logger,
		ctx:    ctx,
	}, nil
}

func (w *OTelWriter) Write(p []byte) (n int, err error) {
	if w.logger == nil {
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
	} else {
		record.SetTimestamp(time.Now())
	}

	if levelStr, ok := logEntry["level"].(string); ok {
		record.SetSeverity(mapZerologLevelToOTel(levelStr))
		record.SetSeverityText(levelStr)
	}

	if message, ok := logEntry["message"].(string); ok {
		record.SetBody(log.StringValue(message))
	}

	for key, value := range logEntry {
		if key == "time" || key == "level" || key == "message" {
			continue
		}
	
		record.AddAttributes(log.String(key, fmt.Sprintf("%v", value)))
	}

	w.logger.Emit(w.ctx, record)

	return len(p), nil
}

func mapZerologLevelToOTel(level string) log.Severity {
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

func ShutdownOTel() error {
	if otelProvider != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		return otelProvider.Shutdown(ctx)
	}

	return nil
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
			return
		}

		if n != len(p) {
			err = io.ErrShortWrite
			return
		}
	}

	return len(p), nil
}
