/*
 * Copyright 2026 Carver Automation Corporation.
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

package datasvc

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestComposeAgentIdentityIsReadOnly(t *testing.T) {
	for _, runfile := range []string{
		"_main/docker/compose/datasvc.docker.json",
		"_main/docker/compose/datasvc.mtls.json",
	} {
		t.Run(runfile, func(t *testing.T) {
			path, err := runfiles.Rlocation(runfile)
			require.NoError(t, err)

			contents, err := os.ReadFile(path)
			require.NoError(t, err)

			var config Config
			require.NoError(t, json.Unmarshal(contents, &config))

			var agentRole Role
			for _, rule := range config.RBAC.Roles {
				if rule.Identity == "CN=agent.serviceradar,O=ServiceRadar" {
					agentRole = rule.Role
					break
				}
			}

			assert.Equal(t, RoleReader, agentRole)
		})
	}
}
