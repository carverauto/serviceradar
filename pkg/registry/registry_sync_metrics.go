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

package registry

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

const (
	registrySyncMeterName = "serviceradar.registry.sync"

	// Metric names for registry sync observability.
	metricRegistryDeviceCountName   = "registry_device_count"
	metricRegistryCNPGCountName     = "registry_cnpg_device_count"
	metricRegistryCNPGDriftName     = "registry_cnpg_drift"
	metricRegistryCNPGDriftPctName  = "registry_cnpg_drift_percent"
	metricRegistrySyncDurationMsName = "registry_sync_duration_ms"
	metricRegistrySyncTimestampName = "registry_sync_last_timestamp_ms"
	metricRegistrySyncSuccessName   = "registry_sync_success"
)

// registrySyncMetricsObservatory stores the latest registry sync measurements.
type registrySyncMetricsObservatory struct {
	registryDeviceCount atomic.Int64
	cnpgDeviceCount     atomic.Int64
	cnpgDrift           atomic.Int64 // absolute difference
	cnpgDriftPercent    atomic.Int64 // percentage drift
	syncDurationMs      atomic.Int64
	syncTimestampMs     atomic.Int64
	syncSuccess         atomic.Int64 // 1 for success, 0 for failure
}

var (
	//nolint:gochecknoglobals // metric observers are shared singletons
	registrySyncMetricsOnce sync.Once
	//nolint:gochecknoglobals // metric observers are shared singletons
	registrySyncMetricsData = &registrySyncMetricsObservatory{}
	//nolint:gochecknoglobals // metric observers are shared singletons
	registrySyncMetricsGauges struct {
		registryDeviceCount metric.Int64ObservableGauge
		cnpgDeviceCount     metric.Int64ObservableGauge
		cnpgDrift           metric.Int64ObservableGauge
		cnpgDriftPercent    metric.Int64ObservableGauge
		syncDurationMs      metric.Int64ObservableGauge
		syncTimestampMs     metric.Int64ObservableGauge
		syncSuccess         metric.Int64ObservableGauge
	}
	registrySyncMetricsRegistration metric.Registration //nolint:unused,gochecknoglobals // kept to retain callback
)

func initRegistrySyncMetrics() {
	meter := otel.Meter(registrySyncMeterName)

	var err error

	registrySyncMetricsGauges.registryDeviceCount, err = meter.Int64ObservableGauge(
		metricRegistryDeviceCountName,
		metric.WithDescription("Number of devices in the in-memory registry"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsGauges.cnpgDeviceCount, err = meter.Int64ObservableGauge(
		metricRegistryCNPGCountName,
		metric.WithDescription("Number of devices in CNPG unified_devices table"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsGauges.cnpgDrift, err = meter.Int64ObservableGauge(
		metricRegistryCNPGDriftName,
		metric.WithDescription("Absolute difference between registry and CNPG device counts"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsGauges.cnpgDriftPercent, err = meter.Int64ObservableGauge(
		metricRegistryCNPGDriftPctName,
		metric.WithDescription("Percentage drift between registry and CNPG device counts"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsGauges.syncDurationMs, err = meter.Int64ObservableGauge(
		metricRegistrySyncDurationMsName,
		metric.WithDescription("Duration of the last registry sync in milliseconds"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsGauges.syncTimestampMs, err = meter.Int64ObservableGauge(
		metricRegistrySyncTimestampName,
		metric.WithDescription("Unix epoch milliseconds of the last registry sync"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsGauges.syncSuccess, err = meter.Int64ObservableGauge(
		metricRegistrySyncSuccessName,
		metric.WithDescription("1 if the last sync was successful, 0 otherwise"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registration, err := meter.RegisterCallback(func(ctx context.Context, observer metric.Observer) error {
		observer.ObserveInt64(registrySyncMetricsGauges.registryDeviceCount, registrySyncMetricsData.registryDeviceCount.Load())
		observer.ObserveInt64(registrySyncMetricsGauges.cnpgDeviceCount, registrySyncMetricsData.cnpgDeviceCount.Load())
		observer.ObserveInt64(registrySyncMetricsGauges.cnpgDrift, registrySyncMetricsData.cnpgDrift.Load())
		observer.ObserveInt64(registrySyncMetricsGauges.cnpgDriftPercent, registrySyncMetricsData.cnpgDriftPercent.Load())
		observer.ObserveInt64(registrySyncMetricsGauges.syncDurationMs, registrySyncMetricsData.syncDurationMs.Load())
		observer.ObserveInt64(registrySyncMetricsGauges.syncTimestampMs, registrySyncMetricsData.syncTimestampMs.Load())
		observer.ObserveInt64(registrySyncMetricsGauges.syncSuccess, registrySyncMetricsData.syncSuccess.Load())
		return nil
	},
		registrySyncMetricsGauges.registryDeviceCount,
		registrySyncMetricsGauges.cnpgDeviceCount,
		registrySyncMetricsGauges.cnpgDrift,
		registrySyncMetricsGauges.cnpgDriftPercent,
		registrySyncMetricsGauges.syncDurationMs,
		registrySyncMetricsGauges.syncTimestampMs,
		registrySyncMetricsGauges.syncSuccess,
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registrySyncMetricsRegistration = registration
}

// recordRegistrySyncMetrics updates gauges for the latest registry sync.
func recordRegistrySyncMetrics(registryCount, cnpgCount int64, duration time.Duration, success bool) {
	registrySyncMetricsOnce.Do(initRegistrySyncMetrics)

	registrySyncMetricsData.registryDeviceCount.Store(registryCount)
	registrySyncMetricsData.cnpgDeviceCount.Store(cnpgCount)

	// Calculate absolute drift
	var drift int64
	if registryCount > cnpgCount {
		drift = registryCount - cnpgCount
	} else {
		drift = cnpgCount - registryCount
	}
	registrySyncMetricsData.cnpgDrift.Store(drift)

	// Calculate percentage drift
	var driftPercent int64
	if cnpgCount > 0 {
		driftPercent = (drift * 100) / cnpgCount
	}
	registrySyncMetricsData.cnpgDriftPercent.Store(driftPercent)

	// Record duration
	registrySyncMetricsData.syncDurationMs.Store(duration.Milliseconds())
	registrySyncMetricsData.syncTimestampMs.Store(time.Now().UnixMilli())

	// Record success/failure
	if success {
		registrySyncMetricsData.syncSuccess.Store(1)
	} else {
		registrySyncMetricsData.syncSuccess.Store(0)
	}
}

// GetRegistrySyncMetrics returns the current registry sync metrics for external access.
// Useful for alerting on drift thresholds.
func GetRegistrySyncMetrics() (registryCount, cnpgCount, drift, driftPercent int64) {
	return registrySyncMetricsData.registryDeviceCount.Load(),
		registrySyncMetricsData.cnpgDeviceCount.Load(),
		registrySyncMetricsData.cnpgDrift.Load(),
		registrySyncMetricsData.cnpgDriftPercent.Load()
}
