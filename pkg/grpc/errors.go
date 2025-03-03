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

package grpc

import (
	"errors"
)

var (
	errUnknownSecurityMode      = errors.New("unknown security mode")
	errSecurityConfigRequired   = errors.New("security config required for mTLS")
	errInvalidServiceRole       = errors.New("invalid service role")
	errFailedToLoadClientCreds  = errors.New("failed to load client credentials")
	errFailedToLoadServerCreds  = errors.New("failed to load server credentials")
	errFailedToLoadClientCert   = errors.New("failed to load client certificate")
	errFailedToReadCACert       = errors.New("failed to read CA certificate")
	errFailedToAppendCACert     = errors.New("failed to append CA certificate")
	errFailedToLoadServerCert   = errors.New("failed to load server certificate")
	errServiceNotClient         = errors.New("service is not configured as a client")
	errServiceNotServer         = errors.New("service is not configured as a server")
	errFailedWorkloadAPIClient  = errors.New("failed to create workload API client")
	errFailedToCreateX509Source = errors.New("failed to create X.509 source")
	errInvalidServerSPIFFEID    = errors.New("invalid server SPIFFE ID")
	errInvalidTrustDomain       = errors.New("invalid trust domain")
	errConnectionConfigRequired = errors.New("connection config required")
)
