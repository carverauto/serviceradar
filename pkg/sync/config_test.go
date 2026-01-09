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

func TestGetEffectiveDiscoveryInterval(t *testing.T) {
	tests := []struct {
		name           string
		globalInterval models.Duration
		sourceInterval models.Duration
		expected       time.Duration
	}{
		{
			name:           "per-source interval overrides global",
			globalInterval: models.Duration(6 * time.Hour),
			sourceInterval: models.Duration(30 * time.Minute),
			expected:       30 * time.Minute,
		},
		{
			name:           "zero source interval uses global",
			globalInterval: models.Duration(6 * time.Hour),
			sourceInterval: 0,
			expected:       6 * time.Hour,
		},
		{
			name:           "nil source uses global",
			globalInterval: models.Duration(2 * time.Hour),
			sourceInterval: 0, // will pass nil source
			expected:       2 * time.Hour,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{
				DiscoveryInterval: tt.globalInterval,
			}

			var source *models.SourceConfig
			if tt.name != "nil source uses global" {
				source = &models.SourceConfig{
					DiscoveryInterval: tt.sourceInterval,
				}
			}

			result := cfg.GetEffectiveDiscoveryInterval(source)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestGetEffectivePollInterval(t *testing.T) {
	tests := []struct {
		name           string
		globalInterval models.Duration
		sourceInterval models.Duration
		expected       time.Duration
	}{
		{
			name:           "per-source interval overrides global",
			globalInterval: models.Duration(5 * time.Minute),
			sourceInterval: models.Duration(1 * time.Minute),
			expected:       1 * time.Minute,
		},
		{
			name:           "zero source interval uses global",
			globalInterval: models.Duration(5 * time.Minute),
			sourceInterval: 0,
			expected:       5 * time.Minute,
		},
		{
			name:           "nil source uses global",
			globalInterval: models.Duration(10 * time.Minute),
			sourceInterval: 0,
			expected:       10 * time.Minute,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{
				PollInterval: tt.globalInterval,
			}

			var source *models.SourceConfig
			if tt.name != "nil source uses global" {
				source = &models.SourceConfig{
					PollInterval: tt.sourceInterval,
				}
			}

			result := cfg.GetEffectivePollInterval(source)
			assert.Equal(t, tt.expected, result)
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
