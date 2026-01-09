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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
)

type intervalTestCase struct {
	name           string
	globalInterval models.Duration
	sourceInterval models.Duration
	expected       time.Duration
	nilSource      bool
}

func runEffectiveIntervalTests(
	t *testing.T,
	tests []intervalTestCase,
	setConfig func(*Config, models.Duration),
	setSource func(*models.SourceConfig, models.Duration),
	getInterval func(*Config, *models.SourceConfig) time.Duration,
) {
	t.Helper()

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{}
			setConfig(cfg, tt.globalInterval)

			var source *models.SourceConfig
			if !tt.nilSource {
				source = &models.SourceConfig{}
				setSource(source, tt.sourceInterval)
			}

			result := getInterval(cfg, source)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestGetEffectiveIntervals(t *testing.T) {
	type intervalSuite struct {
		name           string
		globalPrimary  time.Duration
		sourceOverride time.Duration
		globalNil      time.Duration
		setConfig      func(*Config, models.Duration)
		setSource      func(*models.SourceConfig, models.Duration)
		get            func(*Config, *models.SourceConfig) time.Duration
	}

	suites := []intervalSuite{
		{
			name:           "discovery interval",
			globalPrimary:  6 * time.Hour,
			sourceOverride: 30 * time.Minute,
			globalNil:      2 * time.Hour,
			setConfig: func(cfg *Config, interval models.Duration) {
				cfg.DiscoveryInterval = interval
			},
			setSource: func(source *models.SourceConfig, interval models.Duration) {
				source.DiscoveryInterval = interval
			},
			get: func(cfg *Config, source *models.SourceConfig) time.Duration {
				return cfg.GetEffectiveDiscoveryInterval(source)
			},
		},
		{
			name:           "poll interval",
			globalPrimary:  5 * time.Minute,
			sourceOverride: 1 * time.Minute,
			globalNil:      10 * time.Minute,
			setConfig: func(cfg *Config, interval models.Duration) {
				cfg.PollInterval = interval
			},
			setSource: func(source *models.SourceConfig, interval models.Duration) {
				source.PollInterval = interval
			},
			get: func(cfg *Config, source *models.SourceConfig) time.Duration {
				return cfg.GetEffectivePollInterval(source)
			},
		},
	}

	for _, suite := range suites {
		t.Run(suite.name, func(t *testing.T) {
			tests := []intervalTestCase{
				{
					name:           "per-source interval overrides global",
					globalInterval: models.Duration(suite.globalPrimary),
					sourceInterval: models.Duration(suite.sourceOverride),
					expected:       suite.sourceOverride,
				},
				{
					name:           "zero source interval uses global",
					globalInterval: models.Duration(suite.globalPrimary),
					sourceInterval: 0,
					expected:       suite.globalPrimary,
				},
				{
					name:           "nil source uses global",
					globalInterval: models.Duration(suite.globalNil),
					expected:       suite.globalNil,
					nilSource:      true,
				},
			}

			runEffectiveIntervalTests(t, tests, suite.setConfig, suite.setSource, suite.get)
		})
	}
}

func TestGetEffectiveSweepInterval(t *testing.T) {
	tests := []struct {
		name           string
		sourceInterval string
		expected       time.Duration
	}{
		{
			name:           "valid per-source sweep interval",
			sourceInterval: "30m",
			expected:       30 * time.Minute,
		},
		{
			name:           "empty source interval uses default",
			sourceInterval: "",
			expected:       1 * time.Hour,
		},
		{
			name:           "invalid source interval uses default",
			sourceInterval: "invalid",
			expected:       1 * time.Hour,
		},
		{
			name:           "nil source uses default",
			sourceInterval: "", // will pass nil source
			expected:       1 * time.Hour,
		},
		{
			name:           "hours format works",
			sourceInterval: "2h",
			expected:       2 * time.Hour,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{}

			var source *models.SourceConfig
			if tt.name != "nil source uses default" {
				source = &models.SourceConfig{
					SweepInterval: tt.sourceInterval,
				}
			}

			result := cfg.GetEffectiveSweepInterval(source)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestMixedSourceIntervals(t *testing.T) {
	cfg := &Config{
		DiscoveryInterval: models.Duration(6 * time.Hour),
		PollInterval:      models.Duration(5 * time.Minute),
	}

	// Source A: custom discovery, default poll
	sourceA := &models.SourceConfig{
		DiscoveryInterval: models.Duration(15 * time.Minute),
		PollInterval:      0,
		SweepInterval:     "2h",
	}

	// Source B: default discovery, custom poll
	sourceB := &models.SourceConfig{
		DiscoveryInterval: 0,
		PollInterval:      models.Duration(30 * time.Second),
		SweepInterval:     "",
	}

	// Source C: all defaults
	sourceC := &models.SourceConfig{}

	// Test Source A
	assert.Equal(t, 15*time.Minute, cfg.GetEffectiveDiscoveryInterval(sourceA))
	assert.Equal(t, 5*time.Minute, cfg.GetEffectivePollInterval(sourceA))
	assert.Equal(t, 2*time.Hour, cfg.GetEffectiveSweepInterval(sourceA))

	// Test Source B
	assert.Equal(t, 6*time.Hour, cfg.GetEffectiveDiscoveryInterval(sourceB))
	assert.Equal(t, 30*time.Second, cfg.GetEffectivePollInterval(sourceB))
	assert.Equal(t, 1*time.Hour, cfg.GetEffectiveSweepInterval(sourceB))

	// Test Source C
	assert.Equal(t, 6*time.Hour, cfg.GetEffectiveDiscoveryInterval(sourceC))
	assert.Equal(t, 5*time.Minute, cfg.GetEffectivePollInterval(sourceC))
	assert.Equal(t, 1*time.Hour, cfg.GetEffectiveSweepInterval(sourceC))
}

func TestSourceKey(t *testing.T) {
	tests := []struct {
		name       string
		tenantID   string
		sourceName string
		expected   string
	}{
		{
			name:       "no tenant",
			tenantID:   "",
			sourceName: "my-source",
			expected:   "my-source",
		},
		{
			name:       "with tenant",
			tenantID:   "tenant-123",
			sourceName: "my-source",
			expected:   "tenant-123:my-source",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := sourceKey(tt.tenantID, tt.sourceName)
			assert.Equal(t, tt.expected, result)
		})
	}
}
