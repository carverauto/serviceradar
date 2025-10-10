package logger

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.31.0"
	"google.golang.org/grpc/credentials"
)

// Static errors to match err113 guidance.
var ErrOTelMetricsDisabled = errors.New("OTel metrics exporter disabled")

// meterProvider tracks the global metrics provider so we can shut it down cleanly.
//
//nolint:gochecknoglobals // global state is required for coordinated shutdown
var meterProvider *sdkmetric.MeterProvider

// guard concurrent initialisation of the metrics provider.
//
//nolint:gochecknoglobals // package-level guard for init logic
var meterMu sync.Mutex

// MetricsConfig captures the information required to initialise the OTEL metrics pipeline.
const (
	defaultServiceName    = "serviceradar"
	defaultServiceVersion = "1.0.0"
)

type MetricsConfig struct {
	ServiceName    string
	ServiceVersion string
	OTel           *OTelConfig
	// ExportInterval controls how often metric data is flushed to the OTLP collector.
	// When zero, the default interval of 15 seconds is used.
	ExportInterval time.Duration
}

// InitializeMetrics configures the global MeterProvider and wires an OTLP exporter so
// in-process instruments (identity map metrics etc.) are delivered to the collector.
//
// It is safe to call this multiple times; subsequent calls will return the already
// initialised provider. If metrics exporting is disabled it returns ErrOTelMetricsDisabled.
func InitializeMetrics(ctx context.Context, config MetricsConfig) (*sdkmetric.MeterProvider, error) {
	if config.OTel == nil || !config.OTel.Enabled || config.OTel.Endpoint == "" {
		return nil, ErrOTelMetricsDisabled
	}

	meterMu.Lock()
	defer meterMu.Unlock()

	if meterProvider != nil {
		return meterProvider, nil
	}

	serviceName := config.ServiceName
	if serviceName == "" {
		serviceName = defaultServiceName
	}

	serviceVersion := config.ServiceVersion
	if serviceVersion == "" {
		serviceVersion = defaultServiceVersion
	}

	opts := []otlpmetricgrpc.Option{
		otlpmetricgrpc.WithEndpoint(config.OTel.Endpoint),
	}

	if config.OTel.Insecure {
		opts = append(opts, otlpmetricgrpc.WithInsecure())
	} else if config.OTel.TLS != nil {
		tlsConfig, err := setupTLSConfig(config.OTel.TLS)
		if err != nil {
			return nil, fmt.Errorf("failed to setup metrics TLS configuration: %w", err)
		}

		creds := credentials.NewTLS(tlsConfig)
		opts = append(opts, otlpmetricgrpc.WithTLSCredentials(creds))
	}

	if len(config.OTel.Headers) > 0 {
		opts = append(opts, otlpmetricgrpc.WithHeaders(config.OTel.Headers))
	}

	exporter, err := otlpmetricgrpc.New(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to create OTLP metric exporter: %w", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(serviceVersion),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create metrics resource: %w", err)
	}

	interval := config.ExportInterval
	if interval <= 0 {
		interval = 15 * time.Second
	}

	reader := sdkmetric.NewPeriodicReader(
		exporter,
		sdkmetric.WithInterval(interval),
	)

	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(reader),
	)

	otel.SetMeterProvider(provider)
	meterProvider = provider

	return meterProvider, nil
}

// shutdownMeterProvider flushes and stops the metrics pipeline.
func shutdownMeterProvider(ctx context.Context) error {
	meterMu.Lock()
	defer meterMu.Unlock()

	if meterProvider == nil {
		return nil
	}

	if err := meterProvider.Shutdown(ctx); err != nil {
		return err
	}

	meterProvider = nil

	return nil
}
