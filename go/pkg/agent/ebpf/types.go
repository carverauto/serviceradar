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

// Package ebpf owns the ServiceRadar agent's shared eBPF runtime boundary.
// Feature packages register probes and translate observations; this package
// owns platform checks, loader lifecycle, map/link cleanup, and runtime errors.
package ebpf

import (
	"context"
	"errors"
	"fmt"

	ciliumebpf "github.com/cilium/ebpf"
)

const (
	DefaultBPFFSPath  = "/sys/fs/bpf"
	DefaultBTFPath    = "/sys/kernel/btf/vmlinux"
	DefaultCgroupPath = "/sys/fs/cgroup"

	DetailLibrary        = "library"
	DetailLibraryVersion = "library_version"
	DetailPlatform       = "platform"
	DetailMissingCaps    = "missing_capabilities"
)

const (
	LibraryCiliumEBPF        = "github.com/cilium/ebpf"
	LibraryCiliumEBPFVersion = "v0.21.0"
)

type DisabledReason string

const (
	ReasonConfigDisabled     DisabledReason = "config_disabled"
	ReasonUnsupportedOS      DisabledReason = "unsupported_os"
	ReasonMissingBPFFS       DisabledReason = "missing_bpffs"
	ReasonMissingBTF         DisabledReason = "missing_btf"
	ReasonMissingCgroup      DisabledReason = "missing_cgroup"
	ReasonKernelTooOld       DisabledReason = "kernel_too_old"
	ReasonCapabilityMissing  DisabledReason = "capability_missing"
	ReasonFeatureUnsupported DisabledReason = "feature_unsupported"
	ReasonPermissionDenied   DisabledReason = "permission_denied"
	ReasonSelfTestFailed     DisabledReason = "self_test_failed"
)

var (
	ErrRuntimeDisabled       = errors.New("agent ebpf runtime disabled")
	ErrRuntimeUnavailable    = errors.New("agent ebpf runtime unavailable")
	ErrInvalidCollectionSpec = errors.New("invalid agent ebpf collection spec")
	ErrRuntimeNotImplemented = errors.New("agent ebpf runtime not implemented")
)

type Config struct {
	Enabled bool

	BPFFSPath  string
	BTFPath    string
	CgroupPath string

	AllowMissingBTF    bool
	AllowMissingCgroup bool
	SkipFeatureProbes  bool
}

type CapabilityReport struct {
	Available bool
	Reasons   []DisabledReason
	Details   map[string]string
}

func (r *CapabilityReport) AddReason(reason DisabledReason) {
	if reason == "" || r.HasReason(reason) {
		return
	}
	r.Reasons = append(r.Reasons, reason)
	r.Available = false
}

func (r CapabilityReport) HasReason(reason DisabledReason) bool {
	for _, current := range r.Reasons {
		if current == reason {
			return true
		}
	}
	return false
}

type CollectionLoader func(context.Context) (*ciliumebpf.CollectionSpec, error)

type CollectionSpec struct {
	Name    string
	Load    CollectionLoader
	Options *ciliumebpf.CollectionOptions
}

type AttachPlan struct {
	SessionID string
}

type Observation struct {
	Family   string
	Metadata map[string]string
}

type Collection interface {
	Attach(context.Context, AttachPlan) (SessionHandle, error)
	Close(context.Context) error
}

type SessionHandle interface {
	Events() <-chan Observation
	Close(context.Context) error
}

type Runtime struct {
	config Config
}

func NewRuntime(config Config) *Runtime {
	return &Runtime{config: normalizeConfig(config)}
}

func DefaultRuntime() *Runtime {
	return NewRuntime(Config{})
}

func (r *Runtime) Config() Config {
	if r == nil {
		return normalizeConfig(Config{})
	}
	return r.config
}

func StaticCollectionSpec(name string, load func() (*ciliumebpf.CollectionSpec, error)) CollectionSpec {
	return CollectionSpec{
		Name: name,
		Load: func(context.Context) (*ciliumebpf.CollectionSpec, error) {
			return load()
		},
	}
}

func (s CollectionSpec) validate() error {
	if s.Name == "" {
		return fmt.Errorf("%w: missing name", ErrInvalidCollectionSpec)
	}
	if s.Load == nil {
		return fmt.Errorf("%w: %s missing loader", ErrInvalidCollectionSpec, s.Name)
	}
	return nil
}

func (s CollectionSpec) load(ctx context.Context) (*ciliumebpf.CollectionSpec, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	spec, err := s.Load(ctx)
	if err != nil {
		return nil, fmt.Errorf("%s collection spec: %w", s.Name, err)
	}
	if spec == nil {
		return nil, fmt.Errorf("%w: %s loader returned nil", ErrInvalidCollectionSpec, s.Name)
	}
	return spec, nil
}

func baseReport(platform string) CapabilityReport {
	return CapabilityReport{
		Available: true,
		Details: map[string]string{
			DetailLibrary:        LibraryCiliumEBPF,
			DetailLibraryVersion: LibraryCiliumEBPFVersion,
			DetailPlatform:       platform,
		},
	}
}

func normalizeConfig(config Config) Config {
	if config.BPFFSPath == "" {
		config.BPFFSPath = DefaultBPFFSPath
	}
	if config.BTFPath == "" {
		config.BTFPath = DefaultBTFPath
	}
	if config.CgroupPath == "" {
		config.CgroupPath = DefaultCgroupPath
	}
	return config
}
