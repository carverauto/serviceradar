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

// Package db provides data models for the database service.
package db

import "time"

// PollerHistoryPoint represents a single point in a poller's history.
type PollerHistoryPoint struct {
	Timestamp time.Time `json:"timestamp"`
	IsHealthy bool      `json:"is_healthy"`
}

// PollerStatus represents a poller's current status.
type PollerStatus struct {
	PollerID  string    `json:"poller_id"`
	IsHealthy bool      `json:"is_healthy"`
	FirstSeen time.Time `json:"first_seen"`
	LastSeen  time.Time `json:"last_seen"`
}

// ServiceStatus represents a service's status.
type ServiceStatus struct {
	PollerID    string    `json:"poller_id"`
	ServiceName string    `json:"service_name"`
	ServiceType string    `json:"service_type"`
	Available   bool      `json:"available"`
	Details     string    `json:"details"`
	Timestamp   time.Time `json:"timestamp"`
}

type SNMPMetric struct {
	OIDName   string      `json:"oid_name"`
	Value     interface{} `json:"value"`
	ValueType string      `json:"value_type"`
	Timestamp time.Time   `json:"timestamp"`
	Scale     float64     `json:"scale"`
	IsDelta   bool        `json:"is_delta"`
}

// RperfMetric represents an rperf metric to be stored.
type RperfMetric struct {
	Target      string  `json:"target"`
	Success     bool    `json:"success"`
	Error       *string `json:"error,omitempty"`
	BitsPerSec  float64 `json:"bits_per_second"`
	BytesRecv   int64   `json:"bytes_received"`
	BytesSent   int64   `json:"bytes_sent"`
	Duration    float64 `json:"duration"`
	JitterMs    float64 `json:"jitter_ms"`
	LossPercent float64 `json:"loss_percent"`
	PacketsLost int64   `json:"packets_lost"`
	PacketsRecv int64   `json:"packets_received"`
	PacketsSent int64   `json:"packets_sent"`
}
