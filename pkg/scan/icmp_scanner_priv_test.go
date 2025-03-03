//go:build icmp_privileged

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

package scan

func TestICMPScanner_Scan_InvalidTargets(t *testing.T) {
	ctrl, ctx := gomock.WithContext(context.Background(), t)
	defer ctrl.Finish()

	scanner, err := NewICMPScanner(1*time.Second, 1, 3)
	require.NoError(t, err)

	targets := []models.Target{
		{Host: "invalid.host", Mode: models.ModeICMP},
	}

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	// Count results channel to ensure proper behavior
	resultCount := 0
	for range results {
		resultCount++
	}

	// We expect one result for the invalid target, with Available=false
	assert.Equal(t, 1, resultCount, "Expected one result for invalid target")

	// Clean up
	err = scanner.Stop(ctx)
	require.NoError(t, err)
}

func TestNewICMPScanner_Error(t *testing.T) {
	// Simulate an error by passing invalid parameters
	_, err := NewICMPScanner(0, 0, 0) // All parameters are invalid
	require.Error(t, err, "Expected error for invalid parameters")
}

func TestICMPScanner_SocketError(t *testing.T) {
	scanner, err := NewICMPScanner(1*time.Second, 1, 3)
	require.NoError(t, err, "Expected error for invalid socket")

	scanner.rawSocket = -1 // Invalid socket

	targets := []models.Target{
		{Host: "127.0.0.1", Mode: models.ModeICMP},
	}

	_, err = scanner.Scan(context.Background(), targets)
	require.Error(t, err, "Expected error for invalid socket")
}
