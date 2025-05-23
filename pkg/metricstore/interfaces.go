/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package metricstore pkg/metricstore/interfaces.go
package metricstore

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_metricstore.go -package=metricstore github.com/carverauto/serviceradar/pkg/metricstore RperfManager,SNMPManager

// RperfManager defines the interface for managing rperf metrics.
type RperfManager interface {
	StoreRperfMetric(ctx context.Context, pollerID string, metric *models.RperfMetric, timestamp time.Time) error
	GetRperfMetrics(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]*models.RperfMetric, error)
}

// SNMPManager defines the interface for managing SNMP metrics.
type SNMPManager interface {
	GetSNMPMetrics(ctx context.Context, nodeID string, startTime, endTime time.Time) ([]models.SNMPMetric, error)
}
