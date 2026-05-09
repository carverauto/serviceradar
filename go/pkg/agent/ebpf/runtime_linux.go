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
	"os"
	"runtime"
	"syscall"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/features"
)

const DetailKernelRelease = "kernel_release"

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
		checkFeature(&report, features.HaveMapType(ebpf.Hash))
		checkFeature(&report, features.HaveMapType(ebpf.RingBuf))
		checkFeature(&report, features.HaveProgramType(ebpf.TracePoint))
		checkFeature(&report, features.HaveProgramType(ebpf.Kprobe))
	}

	report.Available = len(report.Reasons) == 0
	return report
}

func checkFeature(report *CapabilityReport, err error) {
	if err == nil {
		return
	}
	switch {
	case errors.Is(err, ebpf.ErrNotSupported):
		report.AddReason(ReasonFeatureUnsupported)
	case errors.Is(err, os.ErrPermission), errors.Is(err, syscall.EPERM), errors.Is(err, syscall.EACCES):
		report.AddReason(ReasonPermissionDenied)
	default:
		report.AddReason(ReasonSelfTestFailed)
	}
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
