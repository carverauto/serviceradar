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

// Package armis pkg/sync/integrations/errors.go
package armis

import "errors"

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
	errAuthFailed           = errors.New("authentication failed")
	errSearchRequestFailed  = errors.New("search request failed")
	errNetworkError         = errors.New("network error")      // Added from lines 329 and 569
	errKVWriteError         = errors.New("KV write error")     // Added from line 350
	errConnectionRefused    = errors.New("connection refused") // Added from line 496
	errNotImplemented       = errors.New("not implemented")
	errNoQueriesProvided    = errors.New("no queries provided in config; at least one query is required")
)
