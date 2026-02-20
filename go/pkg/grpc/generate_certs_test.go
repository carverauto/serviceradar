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

package grpc

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestGenerateTestCertificates(t *testing.T) {
	tmpDir := t.TempDir()

	err := GenerateTestCertificates(tmpDir)
	require.NoError(t, err)

	// Verify all files exist
	files := []string{
		"root.pem",
		"root-key.pem",
		"server.pem",
		"server-key.pem",
		"client.pem",
		"client-key.pem",
	}
	for _, file := range files {
		path := filepath.Join(tmpDir, file)
		_, err := os.Stat(path)
		require.NoError(t, err, "Failed to verify file existence: %s", file)
	}
}
