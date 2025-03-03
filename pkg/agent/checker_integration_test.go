//go:build integration
// +build integration

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

package agent

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestICMPChecker(t *testing.T) {
	tests := []struct {
		name string
		host string
	}{
		{
			name: "localhost",
			host: "127.0.0.1",
		},
		{
			name: "invalid host",
			host: "invalid.host",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			checker := &ICMPChecker{
				Host:  tt.host,
				Count: 1,
			}

			ctx := context.Background()
			available, response := checker.Check(ctx)

			// We can't reliably test the actual ping result as it depends on the
			// network, but we can verify the response format
			assert.NotEmpty(t, response)
			assert.Contains(t, response, tt.host)

			if available {
				assert.Contains(t, response, "response_time")
				assert.Contains(t, response, "packet_loss")
			}

			// Test Close
			err := checker.Close(ctx)
			assert.NoError(t, err)
		})
	}
}
