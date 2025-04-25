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

package cli

import (
	"errors"
	"fmt"
)

var (
	errConfigReadFailed     = errors.New("failed to read config file")
	errConfigMarshalFailed  = errors.New("failed to serialize config")
	errConfigWriteFailed    = errors.New("failed to write config file")
	errInvalidAuthFormat    = errors.New("invalid auth configuration format")
	errEmptyPassword        = fmt.Errorf("password cannot be empty")
	errInvalidCost          = fmt.Errorf("cost must be a number between %d and %d", minCost, maxCost)
	errHashFailed           = fmt.Errorf("failed to generate hash")
	errRequiresFileAndHash  = errors.New("update-config requires -file and -admin-hash")
	errUpdatingConfig       = errors.New("failed to update config file")
	errRequiresPollerFile   = errors.New("update-poller requires -file")
	errUpdatingPollerConfig = errors.New("failed to update poller config file")
	errAgentNotFound        = errors.New("specified agent not found in poller configuration")
	errUnsupportedAction    = errors.New("unsupported action (supported: add, remove)")
	errNoDefaultDetails     = errors.New("no default details for service type %s")
	errServiceTypeRequired  = errors.New("service type is required (use -type)")
	errCheckerNotFound      = errors.New("checker %s no found for agent %s")
)
