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

package poller

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestConfig_OTelConfiguration(t *testing.T) {
	t.Run("config with OTel enabled", func(t *testing.T) {
		jsonConfig := `{
			"agents": {
				"test-agent": {
					"address": ":50051",
					"checks": [{
						"service_type": "icmp",
						"service_name": "ping",
						"details": "1.1.1.1"
					}]
				}
			},
			"core_address": "127.0.0.1:50052",
			"listen_addr": ":50053",
			"poll_interval": "30s",
			"poller_id": "test-poller",
			"partition": "default",
			"source_ip": "127.0.0.1",
			"logging": {
				"level": "info",
				"debug": false,
				"output": "stdout",
				"otel": {
					"enabled": true,
					"endpoint": "localhost:4317",
					"headers": {
						"Authorization": "Bearer test-token"
					},
					"service_name": "serviceradar-poller",
					"batch_timeout": "10s",
					"insecure": false
				}
			}
		}`

		var cfg Config
		err := json.Unmarshal([]byte(jsonConfig), &cfg)
		require.NoError(t, err)

		// Validate the config
		err = cfg.Validate()
		require.NoError(t, err)

		// Check logging config
		assert.NotNil(t, cfg.Logging)
		assert.Equal(t, "info", cfg.Logging.Level)
		assert.False(t, cfg.Logging.Debug)
		assert.Equal(t, "stdout", cfg.Logging.Output)

		// Check OTel config
		assert.NotNil(t, cfg.Logging.OTel)
		assert.True(t, cfg.Logging.OTel.Enabled)
		assert.Equal(t, "localhost:4317", cfg.Logging.OTel.Endpoint)
		assert.Equal(t, "serviceradar-poller", cfg.Logging.OTel.ServiceName)
		assert.Equal(t, logger.Duration(10*time.Second), cfg.Logging.OTel.BatchTimeout)
		assert.False(t, cfg.Logging.OTel.Insecure)
		assert.Equal(t, "Bearer test-token", cfg.Logging.OTel.Headers["Authorization"])
	})

	t.Run("config with OTel disabled", func(t *testing.T) {
		jsonConfig := `{
			"agents": {
				"test-agent": {
					"address": ":50051",
					"checks": [{
						"service_type": "icmp",
						"service_name": "ping",
						"details": "1.1.1.1"
					}]
				}
			},
			"core_address": "127.0.0.1:50052",
			"listen_addr": ":50053",
			"poll_interval": "30s",
			"poller_id": "test-poller",
			"partition": "default",
			"source_ip": "127.0.0.1",
			"logging": {
				"level": "debug",
				"output": "stderr",
				"otel": {
					"enabled": false
				}
			}
		}`

		var cfg Config
		err := json.Unmarshal([]byte(jsonConfig), &cfg)
		require.NoError(t, err)

		// Validate the config
		err = cfg.Validate()
		require.NoError(t, err)

		// Check logging config
		assert.NotNil(t, cfg.Logging)
		assert.Equal(t, "debug", cfg.Logging.Level)
		assert.Equal(t, "stderr", cfg.Logging.Output)

		// Check OTel config
		assert.NotNil(t, cfg.Logging.OTel)
		assert.False(t, cfg.Logging.OTel.Enabled)
	})

	t.Run("config without logging section", func(t *testing.T) {
		jsonConfig := `{
			"agents": {
				"test-agent": {
					"address": ":50051",
					"checks": [{
						"service_type": "icmp",
						"service_name": "ping",
						"details": "1.1.1.1"
					}]
				}
			},
			"core_address": "127.0.0.1:50052",
			"listen_addr": ":50053",
			"poll_interval": "30s",
			"poller_id": "test-poller",
			"partition": "default",
			"source_ip": "127.0.0.1"
		}`

		var cfg Config
		err := json.Unmarshal([]byte(jsonConfig), &cfg)
		require.NoError(t, err)

		// Validate the config
		err = cfg.Validate()
		require.NoError(t, err)

		// Logging should be nil
		assert.Nil(t, cfg.Logging)
	})
}

func TestConfig_ValidateWithAllFields(t *testing.T) {
	cfg := &Config{
		Agents: map[string]AgentConfig{
			"test": {
				Address: ":50051",
				Checks: []Check{
					{
						Type:            "grpc",
						Name:            "sync",
						Details:         "localhost:50058",
						ResultsInterval: (*models.Duration)(nil),
					},
				},
			},
		},
		CoreAddress:  "localhost:50052",
		ListenAddr:   ":50053",
		ServiceName:  "PollerService",
		PollInterval: models.Duration(30 * time.Second),
		PollerID:     "test-poller",
		Partition:    "default",
		SourceIP:     "192.168.1.1",
		Security:     &models.SecurityConfig{},
		Logging: &logger.Config{
			Level:  "info",
			Output: "stdout",
			OTel: logger.OTelConfig{
				Enabled:     true,
				Endpoint:    "localhost:4317",
				ServiceName: "test-service",
			},
		},
	}

	err := cfg.Validate()
	assert.NoError(t, err)
}
