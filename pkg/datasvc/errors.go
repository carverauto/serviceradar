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

package datasvc

import (
	"errors"
)

var (
	errMTLSRequired           = errors.New("mTLS configuration required")
	errFailedToLoadClientCert = errors.New("failed to load client certificate")
	errFailedToReadCACert     = errors.New("failed to read CA certificate")
	errFailedToParseCACert    = errors.New("failed to parse CA certificate")
	errBucketHistoryTooLarge  = errors.New("bucket_history cannot exceed 255")
	errBucketMaxBytesNegative = errors.New("bucket_max_bytes cannot be negative")
	errNilConfig              = errors.New("kv: nil config provided")
	errNATSNotConfigured      = errors.New("kv: nats connection not configured")
	errNATSReconnectDisabled  = errors.New("kv: nats reconnect unavailable")
	errListenAddrRequired     = errors.New("listen_addr is required")
	errNatsURLRequired        = errors.New("nats_url is required")
	errSecurityRequired       = errors.New("security configuration is required for mTLS")
	errNATSSecurityRequired   = errors.New("nats_security configuration is required")
	errCertFileRequired       = errors.New("tls.cert_file is required for mTLS")
	errKeyFileRequired        = errors.New("tls.key_file is required for mTLS")
	errCAFileRequired         = errors.New("tls.ca_file is required for mTLS")
	errInvalidSecurityMode    = errors.New("unsupported security mode")
)

// ErrCASMismatch indicates a compare-and-swap failure due to a stale revision.
var ErrCASMismatch = errors.New("kv: compare-and-swap mismatch")

// ErrKeyExists indicates that a create/put-if-absent operation found an existing value.
var ErrKeyExists = errors.New("kv: key already exists")

// ErrObjectNotFound indicates that a requested object does not exist.
var ErrObjectNotFound = errors.New("kv: object not found")
