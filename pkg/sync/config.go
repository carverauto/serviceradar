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

package sync

import (
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultTimeout = 30 * time.Second
)

var (
	errMissingSources = errors.New("at least one source must be defined")
	errMissingKV      = errors.New("kv_address is required")
	errMissingFields  = errors.New("source missing required fields (type, endpoint, prefix)")
)

type Config struct {
	Sources      map[string]models.SourceConfig `json:"sources"`       // e.g., "armis": {...}, "netbox": {...}
	KVAddress    string                         `json:"kv_address"`    // KV gRPC server address
	PollInterval config.Duration                `json:"poll_interval"` // Polling interval
	Security     *models.SecurityConfig         `json:"security"`      // mTLS config
}

func (c *Config) Validate() error {
	if len(c.Sources) == 0 {
		return errMissingSources
	}

	if c.KVAddress == "" {
		return errMissingKV
	}

	if time.Duration(c.PollInterval) == 0 {
		c.PollInterval = config.Duration(defaultTimeout)
	}

	if c.Security == nil || c.Security.ServerName == "" {
		return errors.New("security.server_name is required for mTLS and RBAC")
	}

	for name, src := range c.Sources {
		if src.Type == "" || src.Endpoint == "" || src.Prefix == "" {
			return fmt.Errorf("source %s: %w", name, errMissingFields)
		}
	}

	return nil
}
