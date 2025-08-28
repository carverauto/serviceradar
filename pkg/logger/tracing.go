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
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.31.0"
	otelTrace "go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/credentials"
)

// TracingConfig holds the configuration for OpenTelemetry tracing setup
type TracingConfig struct {
	ServiceName    string
	ServiceVersion string
	Debug          bool
	Logger         Logger      // Optional logger for debug output
	OTel           *OTelConfig // Optional OTel configuration for trace exporting
}

// InitializeTracing sets up OpenTelemetry tracing and returns a traced context with a root span.
// This should be called once at application startup.
//
// Returns:
//   - *trace.TracerProvider: The tracer provider (caller should defer tp.Shutdown())
//   - context.Context: A context containing the root span
//   - otelTrace.Span: The root span (caller should defer span.End())
//   - error: Any initialization error
//
// Example usage:
//
//	tp, ctx, rootSpan, err := logger.InitializeTracing(context.Background(), logger.TracingConfig{
//	    ServiceName:    "my-service",
//	    ServiceVersion: "1.0.0",
//	    Debug:          true,
//	    OTel:           &config.Logging.OTel,
//	})
//	if err != nil {
//	    return err
//	}
//	defer func() { tp.Shutdown(context.Background()) }()
//	defer rootSpan.End()
func InitializeTracing(ctx context.Context, config TracingConfig) (*trace.TracerProvider, context.Context, otelTrace.Span, error) {
	// Set defaults
	if config.ServiceName == "" {
		config.ServiceName = "serviceradar"
	}

	if config.ServiceVersion == "" {
		config.ServiceVersion = "1.0.0"
	}

	// Create resource with service information
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(config.ServiceName),
			semconv.ServiceVersion(config.ServiceVersion),
		),
	)
	if err != nil {
		return nil, ctx, nil, fmt.Errorf("failed to create OpenTelemetry resource: %w", err)
	}

	// Create TracerProvider options
	var tpOptions []trace.TracerProviderOption

	tpOptions = append(tpOptions, trace.WithResource(res))

	// Add trace exporter if OTel config is provided
	if config.OTel != nil && config.OTel.Enabled && config.OTel.Endpoint != "" {
		exporter, err := createTraceExporter(ctx, config.OTel)
		if err != nil {
			return nil, ctx, nil, fmt.Errorf("failed to create trace exporter: %w", err)
		}

		// Use BatchSpanProcessor for efficient trace exporting
		bsp := trace.NewBatchSpanProcessor(exporter)
		tpOptions = append(tpOptions, trace.WithSpanProcessor(bsp))
	}

	// Create TracerProvider with the resource and optional exporter
	tp := trace.NewTracerProvider(tpOptions...)

	// Set the global TracerProvider and propagator
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// Create a tracer for this service
	tracer := otel.Tracer(config.ServiceName)

	// Create a root span for the service lifetime
	spanName := config.ServiceName + ".main"
	ctx, rootSpan := tracer.Start(ctx, spanName)

	// Debug logging if enabled
	if config.Debug {
		logTracingInitialization(config, rootSpan)
	}

	return tp, ctx, rootSpan, nil
}

// GetTracer returns a tracer for the given name.
// This is a convenience function that calls otel.Tracer().
// InitializeTracing must be called first to set up the global TracerProvider.
func GetTracer(name string) otelTrace.Tracer {
	return otel.Tracer(name)
}

// logTracingInitialization handles debug logging for tracing initialization.
// This is extracted to reduce nesting complexity in the InitializeTracing function.
func logTracingInitialization(config TracingConfig, span otelTrace.Span) {
	spanCtx := span.SpanContext()

	// If span context is not valid, log a warning
	if !spanCtx.IsValid() {
		if config.Logger != nil {
			config.Logger.Warn().
				Str("service", config.ServiceName).
				Msg("Warning - span context is not valid")
		} else {
			fmt.Printf("DEBUG: Warning - span context is not valid for %s\n", config.ServiceName)
		}

		return
	}

	// Log successful initialization
	if config.Logger != nil {
		config.Logger.Debug().
			Str("service", config.ServiceName).
			Str("trace_id", spanCtx.TraceID().String()).
			Str("span_id", spanCtx.SpanID().String()).
			Msg("Initialized OpenTelemetry tracing")
	} else {
		fmt.Printf("DEBUG: Initialized tracing for %s with trace_id=%s span_id=%s\n",
			config.ServiceName, spanCtx.TraceID().String(), spanCtx.SpanID().String())
	}
}

// createTraceExporter creates an OTLP trace exporter based on the provided configuration
func createTraceExporter(ctx context.Context, config *OTelConfig) (trace.SpanExporter, error) {
	opts := []otlptracegrpc.Option{
		otlptracegrpc.WithEndpoint(config.Endpoint),
	}

	if config.Insecure {
		opts = append(opts, otlptracegrpc.WithInsecure())
	} else if config.TLS != nil {
		tlsConfig, err := setupTLSConfig(config.TLS)
		if err != nil {
			return nil, fmt.Errorf("failed to setup TLS configuration: %w", err)
		}

		creds := credentials.NewTLS(tlsConfig)
		opts = append(opts, otlptracegrpc.WithTLSCredentials(creds))
	}

	if len(config.Headers) > 0 {
		opts = append(opts, otlptracegrpc.WithHeaders(config.Headers))
	}

	return otlptracegrpc.New(ctx, opts...)
}
