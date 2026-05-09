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

package probes

import "testing"

func TestLoadSelftestSpec(t *testing.T) {
	t.Parallel()

	spec, err := LoadSelftestSpec()
	if err != nil {
		t.Fatalf("LoadSelftestSpec() error = %v", err)
	}
	if spec.Programs[SelftestProgramName] == nil {
		t.Fatalf("self-test program %q missing from spec", SelftestProgramName)
	}
}
