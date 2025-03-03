/*-
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

package metrics

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_buffer.go -package=metrics github.com/carverauto/serviceradar/pkg/metrics MetricStore,MetricCollector

type MetricStore interface {
	Add(timestamp time.Time, responseTime int64, serviceName string)
	GetPoints() []models.MetricPoint
	GetLastPoint() *models.MetricPoint // New method
}

type MetricCollector interface {
	AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error
	GetMetrics(nodeID string) []models.MetricPoint
	CleanupStaleNodes(staleDuration time.Duration)
}
