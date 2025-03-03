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

// Package models pkg/models/metrics.go
package models

import "time"

type MetricPoint struct {
	Timestamp    time.Time `json:"timestamp"`
	ResponseTime int64     `json:"response_time"`
	ServiceName  string    `json:"service_name"`
}

type MetricsConfig struct {
	Enabled   bool `json:"metrics_enabled"`
	Retention int  `json:"metrics_retention"`
	MaxNodes  int  `json:"max_nodes"`
}

const MetricPointSize = 32 // 8 bytes timestamp + 8 bytes response + 16 bytes name
