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

package db

import "errors"

var (
	// Core database errors.
	ErrFailedOpenDB = errors.New("failed to open database")

	// CNPG configuration helpers.
	ErrCNPGConfigMissing   = errors.New("cnpg: missing configuration")
	ErrCNPGLackingTLSFiles = errors.New("cnpg tls requires cert_file, key_file, and ca_file")
	ErrCNPGTLSDisabled     = errors.New("cnpg tls configuration requires sslmode not be disable")
)
