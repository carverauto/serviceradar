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

package dusk

import (
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Config represents Dusk checker configuration.
type Config struct {
	NodeAddress string                 `json:"node_address"`
	Timeout     config.Duration        `json:"timeout"`
	ListenAddr  string                 `json:"listen_addr"`
	Security    *models.SecurityConfig `json:"security"`
}

const (
	defaultTimeout = 5 * time.Minute
)

var (
	errNodeAddressRequired = fmt.Errorf("node_address is required")
	errListenAddrRequired  = fmt.Errorf("listen_addr is required")
)

// Validate implements config.Validator interface.
func (c *Config) Validate() error {
	if c.NodeAddress == "" {
		return errNodeAddressRequired
	}

	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	// Cast to time.Duration for comparison
	if time.Duration(c.Timeout) == 0 {
		// Assign a default by constructing a config.Duration
		c.Timeout = config.Duration(defaultTimeout)
	}

	return nil
}
