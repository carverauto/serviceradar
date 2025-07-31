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
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.31.0"
	otelTrace "go.opentelemetry.io/otel/trace"
)

// TracingConfig holds the configuration for OpenTelemetry tracing setup
type TracingConfig struct {
	ServiceName    string
	ServiceVersion string
	Debug          bool
	Logger         Logger // Optional logger for debug output
}

// InitializeTracing sets up OpenTelemetry tracing and returns a traced context with a root span.
// This should be called once at application startup.
//
// Returns:
//   - context.Context: A context containing the root span
//   - otelTrace.Span: The root span (caller should defer span.End())
//   - error: Any initialization error
//
// Example usage:
//
//	ctx, rootSpan, err := logger.InitializeTracing(context.Background(), logger.TracingConfig{
//	    ServiceName:    "my-service",
//	    ServiceVersion: "1.0.0",
//	    Debug:          true,
//	})
//	if err != nil {
//	    return err
//	}
//	defer rootSpan.End()
func InitializeTracing(ctx context.Context, config TracingConfig) (context.Context, otelTrace.Span, error) {
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
		return ctx, nil, fmt.Errorf("failed to create OpenTelemetry resource: %w", err)
	}

	// Create TracerProvider with the resource
	tp := trace.NewTracerProvider(
		trace.WithResource(res),
	)

	// Set the global TracerProvider
	otel.SetTracerProvider(tp)

	// Create a tracer for this service
	tracer := otel.Tracer(config.ServiceName)

	// Create a root span for the service lifetime
	spanName := config.ServiceName + ".main"
	ctx, rootSpan := tracer.Start(ctx, spanName)

	// Debug logging if enabled
	if config.Debug {
		logTracingInitialization(config, rootSpan)
	}

	return ctx, rootSpan, nil
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
