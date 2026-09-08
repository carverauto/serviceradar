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

package ebpf

import (
	"context"
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

func TestCapabilityReportAddReasonDeduplicatesAndDisables(t *testing.T) {
	t.Parallel()

	report := CapabilityReport{Available: true}
	report.AddReason(ReasonMissingBPFFS)
	report.AddReason(ReasonMissingBPFFS)

	if report.Available {
		t.Fatal("report should be unavailable after a reason is added")
	}
	if len(report.Reasons) != 1 {
		t.Fatalf("reasons = %#v, want one reason", report.Reasons)
	}
	if !report.HasReason(ReasonMissingBPFFS) {
		t.Fatalf("report missing reason %q", ReasonMissingBPFFS)
	}
}

func TestDefaultRuntimeCheckIsDisabled(t *testing.T) {
	t.Parallel()

	report := DefaultRuntime().Check(context.Background())

	if report.Available {
		t.Fatalf("default runtime should be disabled: %#v", report)
	}
	if !report.HasReason(ReasonConfigDisabled) {
		t.Fatalf("report missing reason %q: %#v", ReasonConfigDisabled, report)
	}
	if report.Details[DetailLibrary] != LibraryCiliumEBPF {
		t.Fatalf("library detail = %q", report.Details[DetailLibrary])
	}
}

func TestStaticCollectionSpecLoadsGeneratedSpec(t *testing.T) {
	t.Parallel()

	spec := StaticCollectionSpec("selftest", probes.LoadSelftestSpec)
	collectionSpec, err := spec.load(context.Background())
	if err != nil {
		t.Fatalf("load generated spec: %v", err)
	}
	if collectionSpec.Programs[probes.SelftestProgramName] == nil {
		t.Fatalf("program %q missing from generated spec", probes.SelftestProgramName)
	}
}

func TestLoadCollectionRejectsInvalidSpec(t *testing.T) {
	t.Parallel()

	_, err := DefaultRuntime().LoadCollection(context.Background(), CollectionSpec{Name: "test"})
	if !errors.Is(err, ErrInvalidCollectionSpec) {
		t.Fatalf("LoadCollection error = %v, want %v", err, ErrInvalidCollectionSpec)
	}
}

func TestLoadCollectionReturnsDisabled(t *testing.T) {
	t.Parallel()

	_, err := DefaultRuntime().LoadCollection(
		context.Background(),
		StaticCollectionSpec("selftest", probes.LoadSelftestSpec),
	)
	if !errors.Is(err, ErrRuntimeDisabled) {
		t.Fatalf("LoadCollection error = %v, want %v", err, ErrRuntimeDisabled)
	}
}
