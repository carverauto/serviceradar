//go:build linux

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
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"

	ciliumebpf "github.com/cilium/ebpf"
	"github.com/cilium/ebpf/features"
)

const (
	DetailKernelRelease = "kernel_release"
	DetailKernelMinimum = "kernel_minimum"

	minKernelMajor = 5
	minKernelMinor = 8

	linuxCapPerfmon = 38
	linuxCapBPF     = 39
)

var errCapEffMissing = errors.New("capability effective set missing")

type loadedCollection struct {
	name   string
	raw    *ciliumebpf.Collection
	events chan Observation
}

func (r *Runtime) Check(ctx context.Context) CapabilityReport {
	report := baseReport(runtime.GOOS + "/" + runtime.GOARCH)
	if r == nil {
		r = DefaultRuntime()
	}

	config := r.config
	if !config.Enabled {
		report.AddReason(ReasonConfigDisabled)
		return report
	}

	if kernelRelease := readKernelRelease(); kernelRelease != "" {
		report.Details[DetailKernelRelease] = kernelRelease
		report.Details[DetailKernelMinimum] = "5.8"
		if !kernelAtLeast(kernelRelease, minKernelMajor, minKernelMinor) {
			report.AddReason(ReasonKernelTooOld)
		}
	}

	if ctx.Err() != nil {
		report.AddReason(ReasonSelfTestFailed)
		return report
	}

	if !pathExists(config.BPFFSPath) {
		report.AddReason(ReasonMissingBPFFS)
	}
	if !config.AllowMissingBTF && !pathExists(config.BTFPath) {
		report.AddReason(ReasonMissingBTF)
	}
	if !config.AllowMissingCgroup && !pathExists(config.CgroupPath) {
		report.AddReason(ReasonMissingCgroup)
	}

	if !config.SkipFeatureProbes {
		checkRequiredCaps(&report)
		checkFeature(&report, features.HaveMapType(ciliumebpf.Hash))
		checkFeature(&report, features.HaveMapType(ciliumebpf.RingBuf))
		checkFeature(&report, features.HaveProgramType(ciliumebpf.TracePoint))
		checkFeature(&report, features.HaveProgramType(ciliumebpf.Kprobe))
	}

	report.Available = len(report.Reasons) == 0
	return report
}

func checkRequiredCaps(report *CapabilityReport) {
	missing, err := missingEffectiveCaps(map[string]int{
		"CAP_BPF":     linuxCapBPF,
		"CAP_PERFMON": linuxCapPerfmon,
	})
	if err != nil {
		report.AddReason(ReasonSelfTestFailed)
		return
	}
	if len(missing) == 0 {
		return
	}
	report.AddReason(ReasonCapabilityMissing)
	report.Details[DetailMissingCaps] = strings.Join(missing, ",")
}

func (r *Runtime) LoadCollection(ctx context.Context, spec CollectionSpec) (Collection, error) {
	if err := spec.validate(); err != nil {
		return nil, err
	}
	if r == nil {
		r = DefaultRuntime()
	}
	if !r.config.Enabled {
		return nil, ErrRuntimeDisabled
	}
	if report := r.Check(ctx); !report.Available {
		return nil, fmt.Errorf("%w: %s", ErrRuntimeUnavailable, formatDisabledReasons(report.Reasons))
	}

	collectionSpec, err := spec.load(ctx)
	if err != nil {
		return nil, err
	}

	options := ciliumebpf.CollectionOptions{}
	if spec.Options != nil {
		options = *spec.Options
	}
	raw, err := ciliumebpf.NewCollectionWithOptions(collectionSpec, options)
	if err != nil {
		return nil, fmt.Errorf("load ebpf collection %q: %w", spec.Name, err)
	}

	return &loadedCollection{
		name:   spec.Name,
		raw:    raw,
		events: make(chan Observation),
	}, nil
}

func (c *loadedCollection) Attach(context.Context, AttachPlan) (SessionHandle, error) {
	return nil, ErrRuntimeNotImplemented
}

func (c *loadedCollection) Close(context.Context) error {
	if c == nil || c.raw == nil {
		return nil
	}
	c.raw.Close()
	return nil
}

func checkFeature(report *CapabilityReport, err error) {
	if err == nil {
		return
	}
	switch {
	case errors.Is(err, ciliumebpf.ErrNotSupported):
		report.AddReason(ReasonFeatureUnsupported)
	case errors.Is(err, os.ErrPermission), errors.Is(err, syscall.EPERM), errors.Is(err, syscall.EACCES):
		report.AddReason(ReasonPermissionDenied)
	default:
		report.AddReason(ReasonSelfTestFailed)
	}
}

func formatDisabledReasons(reasons []DisabledReason) string {
	if len(reasons) == 0 {
		return "unknown"
	}
	parts := make([]string, 0, len(reasons))
	for _, reason := range reasons {
		parts = append(parts, string(reason))
	}
	return strings.Join(parts, ",")
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func readKernelRelease() string {
	data, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return string(bytesTrimSpace(data))
}

func kernelAtLeast(release string, wantMajor, wantMinor int) bool {
	major, minor, ok := parseKernelMajorMinor(release)
	if !ok {
		return false
	}
	if major != wantMajor {
		return major > wantMajor
	}
	return minor >= wantMinor
}

func parseKernelMajorMinor(release string) (int, int, bool) {
	parts := strings.SplitN(release, ".", 3)
	if len(parts) < 2 {
		return 0, 0, false
	}
	major, err := strconv.Atoi(leadingDigits(parts[0]))
	if err != nil {
		return 0, 0, false
	}
	minor, err := strconv.Atoi(leadingDigits(parts[1]))
	if err != nil {
		return 0, 0, false
	}
	return major, minor, true
}

func leadingDigits(value string) string {
	for i, r := range value {
		if r < '0' || r > '9' {
			return value[:i]
		}
	}
	return value
}

func missingEffectiveCaps(required map[string]int) ([]string, error) {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return nil, err
	}
	return missingEffectiveCapsFromStatus(data, required)
}

func missingEffectiveCapsFromStatus(data []byte, required map[string]int) ([]string, error) {
	capEff, ok := parseCapEff(data)
	if !ok {
		return nil, errCapEffMissing
	}
	missing := make([]string, 0, len(required))
	for name, bit := range required {
		if capEff&(uint64(1)<<bit) == 0 {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	return missing, nil
}

func parseCapEff(data []byte) (uint64, bool) {
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "CapEff:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(line, "CapEff:"))
		capEff, err := strconv.ParseUint(value, 16, 64)
		return capEff, err == nil
	}
	return 0, false
}

func bytesTrimSpace(data []byte) []byte {
	for len(data) > 0 {
		switch data[0] {
		case ' ', '\n', '\r', '\t':
			data = data[1:]
		default:
			goto trimRight
		}
	}

trimRight:
	for len(data) > 0 {
		switch data[len(data)-1] {
		case ' ', '\n', '\r', '\t':
			data = data[:len(data)-1]
		default:
			return data
		}
	}
	return data
}
