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

package models

// ServerConfig holds the agent server configuration.
type ServerConfig struct {
	ListenAddr string          `json:"listen_addr"`
	Security   *SecurityConfig `json:"security"`
}

type ServiceRole string

const (
	RolePoller  ServiceRole = "poller"  // Client and Server
	RoleAgent   ServiceRole = "agent"   // Server only
	RoleCloud   ServiceRole = "cloud"   // Server only
	RoleChecker ServiceRole = "checker" // Server only (for SNMP, Dusk checkers)
)

// SecurityConfig holds common security configuration.
type SecurityConfig struct {
	Mode           SecurityMode `json:"mode"`
	CertDir        string       `json:"cert_dir"`
	ServerName     string       `json:"server_name,omitempty"`
	Role           ServiceRole  `json:"role"`
	TrustDomain    string       `json:"trust_domain,omitempty"`    // For SPIFFE
	WorkloadSocket string       `json:"workload_socket,omitempty"` // For SPIFFE
}

// SecurityMode defines the type of security to use.
type SecurityMode string
