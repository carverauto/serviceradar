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

package armis

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
)

func TestArmisIntegration_PrepareArmisUpdate(t *testing.T) {
	armisInteg := &ArmisIntegration{
		Config: &models.SourceConfig{
			Endpoint: "http://serviceradar.example.com",
		},
	}

	devices := []Device{
		{
			ID:        1,
			IPAddress: "192.168.1.1",
			Name:      "Device1",
		},
		{
			ID:        2,
			IPAddress: "192.168.1.2, 10.0.0.1", // Multiple IPs
			Name:      "Device2",
		},
		{
			ID:        3,
			IPAddress: "192.168.1.3",
			Name:      "Device3",
		},
	}

	sweepResults := []SweepResult{
		{
			IP:        "192.168.1.1",
			Available: true,
			Timestamp: time.Now(),
			RTT:       10.5,
		},
		{
			IP:        "192.168.1.2",
			Available: false,
			Timestamp: time.Now(),
		},
		// No result for 192.168.1.3
	}

	updates := armisInteg.PrepareArmisUpdate(context.Background(), devices, sweepResults)

	assert.Len(t, updates, 3)

	// Check device 1
	assert.Equal(t, 1, updates[0].DeviceID)
	assert.Equal(t, "192.168.1.1", updates[0].IP)
	assert.True(t, updates[0].Available)
	assert.InDelta(t, 10.5, updates[0].RTT, 0.0001)

	// Check device 2 (should use first IP)
	assert.Equal(t, 2, updates[1].DeviceID)
	assert.Equal(t, "192.168.1.2", updates[1].IP)
	assert.False(t, updates[1].Available)

	// Check device 3 (no sweep result)
	assert.Equal(t, 3, updates[2].DeviceID)
	assert.Equal(t, "192.168.1.3", updates[2].IP)
	assert.False(t, updates[2].Available)
	assert.Zero(t, updates[2].RTT)
}

func TestExtractFirstIP(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"Single IP", "192.168.1.1", "192.168.1.1"},
		{"Multiple IPs", "192.168.1.1, 10.0.0.1, 172.16.0.1", "192.168.1.1"},
		{"IP with spaces", " 192.168.1.1 ", "192.168.1.1"},
		{"Empty string", "", ""},
		{"Multiple IPs no space", "192.168.1.1,10.0.0.1", "192.168.1.1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractFirstIP(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}
