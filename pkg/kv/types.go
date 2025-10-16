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

package kv

import (
	"github.com/carverauto/serviceradar/pkg/models"
)

// Role defines a role in the RBAC system.
type Role string

const (
	RoleReader Role = "reader"
	RoleWriter Role = "writer"
)

// RBACRule maps a client identity to a role.
type RBACRule struct {
	Identity string `json:"identity"`
	Role     Role   `json:"role"`
}

// Config holds the configuration for the KV service.
type Config struct {
	ListenAddr string                 `json:"listen_addr"`
	NATSURL    string                 `json:"nats_url"`
	Security   *models.SecurityConfig `json:"security"`
	RBAC       struct {
		Roles []RBACRule `json:"roles"`
	} `json:"rbac"`
	Bucket         string          `json:"bucket,omitempty"`           // KV bucket name
	Domain         string          `json:"domain,omitempty"`           // Optional JetStream domain
	BucketMaxBytes int64           `json:"bucket_max_bytes,omitempty"` // Hard cap for bucket size (bytes)
	BucketTTL      models.Duration `json:"bucket_ttl,omitempty"`       // TTL for entries (0 = no expiry)
	BucketHistory  uint32          `json:"bucket_history,omitempty"`   // History depth per key
}
