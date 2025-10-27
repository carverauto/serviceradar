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

package models

type ServiceRole string

const (
	RolePoller      ServiceRole = "poller"  // Client and Server
	RoleAgent       ServiceRole = "agent"   // Server only
	RoleCore        ServiceRole = "core"    // Server only
	RoleKVStore     ServiceRole = "kv"      // Server only
	RoleDataService ServiceRole = "datasvc" // Client and Server (NATS + gRPC)
	RoleChecker     ServiceRole = "checker" // Server only (for SNMP, Dusk checkers)
)

type TLSConfig struct {
	CertFile     string `json:"cert_file"`
	KeyFile      string `json:"key_file"`
	CAFile       string `json:"ca_file"`
	ClientCAFile string `json:"client_ca_file"`
}

// SecurityConfig holds common security configuration.
type SecurityConfig struct {
	Mode           SecurityMode `json:"mode"`
	CertDir        string       `json:"cert_dir"`
	ServerName     string       `json:"server_name,omitempty"`
	Role           ServiceRole  `json:"role"`
	TLS            TLSConfig    `json:"tls"`
	TrustDomain    string       `json:"trust_domain,omitempty"`     // For SPIFFE
	ServerSPIFFEID string       `json:"server_spiffe_id,omitempty"` // Expected SPIFFE ID when acting as client
	WorkloadSocket string       `json:"workload_socket,omitempty"`  // For SPIFFE
}

// SecurityMode defines the type of security to use.
type SecurityMode string
