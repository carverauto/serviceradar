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

package probes_test

import (
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

func TestLoadSelftestSpec(t *testing.T) {
	t.Parallel()

	spec, err := probes.LoadSelftestSpec()
	if err != nil {
		t.Fatalf("LoadSelftestSpec() error = %v", err)
	}
	if spec.Programs[probes.SelftestProgramName] == nil {
		t.Fatalf("self-test program %q missing from spec", probes.SelftestProgramName)
	}
}

func TestLoadCommandSpec(t *testing.T) {
	t.Parallel()

	spec, err := probes.LoadCommandSpec()
	if err != nil {
		t.Fatalf("LoadCommandSpec() error = %v", err)
	}
	if spec.Programs[probes.CommandProgramName] == nil {
		t.Fatalf("command program %q missing from spec", probes.CommandProgramName)
	}
	if spec.Maps[probes.CommandEventsMap] == nil {
		t.Fatalf("command events map %q missing from spec", probes.CommandEventsMap)
	}
	if spec.Maps[probes.CommandLossesMap] == nil {
		t.Fatalf("command losses map %q missing from spec", probes.CommandLossesMap)
	}
}

func TestLoadFileSpec(t *testing.T) {
	t.Parallel()

	spec, err := probes.LoadFileSpec()
	if err != nil {
		t.Fatalf("LoadFileSpec() error = %v", err)
	}
	for _, programName := range []string{probes.FileOpenatProgramName, probes.FileAccessProgramName, probes.FileFAccessatProgramName} {
		if spec.Programs[programName] == nil {
			t.Fatalf("file program %q missing from spec", programName)
		}
	}
	if spec.Maps[probes.FileEventsMap] == nil {
		t.Fatalf("file events map %q missing from spec", probes.FileEventsMap)
	}
	if spec.Maps[probes.FileLossesMap] == nil {
		t.Fatalf("file losses map %q missing from spec", probes.FileLossesMap)
	}
}

func TestLoadNetworkSpec(t *testing.T) {
	t.Parallel()

	spec, err := probes.LoadNetworkSpec()
	if err != nil {
		t.Fatalf("LoadNetworkSpec() error = %v", err)
	}
	if spec.Programs[probes.NetworkConnectProgramName] == nil {
		t.Fatalf("network program %q missing from spec", probes.NetworkConnectProgramName)
	}
	if spec.Maps[probes.NetworkEventsMap] == nil {
		t.Fatalf("network events map %q missing from spec", probes.NetworkEventsMap)
	}
	if spec.Maps[probes.NetworkLossesMap] == nil {
		t.Fatalf("network losses map %q missing from spec", probes.NetworkLossesMap)
	}
}

func TestLossCounterHelpersRejectNilMap(t *testing.T) {
	t.Parallel()

	if _, err := probes.ReadLossCounters(nil); err == nil {
		t.Fatal("ReadLossCounters(nil) error = nil")
	}
	if err := probes.ResetLossCounters(nil); err == nil {
		t.Fatal("ResetLossCounters(nil) error = nil")
	}
}
