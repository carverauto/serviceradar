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
	"errors"
)

var (
	errMTLSRequired           = errors.New("mTLS configuration required")
	errFailedToLoadClientCert = errors.New("failed to load client certificate")
	errFailedToReadCACert     = errors.New("failed to read CA certificate")
	errFailedToParseCACert    = errors.New("failed to parse CA certificate")
	errListenAddrRequired     = errors.New("listen_addr is required")
	errNatsURLRequired        = errors.New("nats_url is required")
	errSecurityRequired       = errors.New("security configuration is required for mTLS")
	errCertFileRequired       = errors.New("tls.cert_file is required for mTLS")
	errKeyFileRequired        = errors.New("tls.key_file is required for mTLS")
	errCAFileRequired         = errors.New("tls.ca_file is required for mTLS")
)
