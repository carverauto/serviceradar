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

func TestLoadCommandSpec(t *testing.T) {
	t.Parallel()

	spec, err := LoadCommandSpec()
	if err != nil {
		t.Fatalf("LoadCommandSpec() error = %v", err)
	}
	if spec.Programs[CommandProgramName] == nil {
		t.Fatalf("command program %q missing from spec", CommandProgramName)
	}
	if spec.Maps[CommandEventsMap] == nil {
		t.Fatalf("command events map %q missing from spec", CommandEventsMap)
	}
}

func TestLoadFileSpec(t *testing.T) {
	t.Parallel()

	spec, err := LoadFileSpec()
	if err != nil {
		t.Fatalf("LoadFileSpec() error = %v", err)
	}
	for _, programName := range []string{FileOpenatProgramName, FileAccessProgramName, FileFAccessatProgramName} {
		if spec.Programs[programName] == nil {
			t.Fatalf("file program %q missing from spec", programName)
		}
	}
	if spec.Maps[FileEventsMap] == nil {
		t.Fatalf("file events map %q missing from spec", FileEventsMap)
	}
}

func TestLoadNetworkSpec(t *testing.T) {
	t.Parallel()

	spec, err := LoadNetworkSpec()
	if err != nil {
		t.Fatalf("LoadNetworkSpec() error = %v", err)
	}
	if spec.Programs[NetworkConnectProgramName] == nil {
		t.Fatalf("network program %q missing from spec", NetworkConnectProgramName)
	}
	if spec.Maps[NetworkEventsMap] == nil {
		t.Fatalf("network events map %q missing from spec", NetworkEventsMap)
	}
}
