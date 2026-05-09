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

package remoteaccess

import (
	"context"
	"os"
)

// PlatformEnhancedRecordingAvailable reports whether this host has a
// ServiceRadar-owned BPF collector that can satisfy required BPF policies.
// The procfs collector returned by NewPlatformEnhancedRecorder is an
// optional/fallback collector and must not advertise the BPF capability.
func PlatformEnhancedRecordingAvailable() bool {
	return false
}

func linuxBPFSurfacesAvailable() bool {
	return pathExists("/sys/fs/bpf") &&
		(pathExists("/sys/kernel/tracing") || pathExists("/sys/kernel/debug/tracing"))
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// NewPlatformEnhancedRecorder returns the Linux host-event fallback collector.
// It reads public procfs surfaces and refuses required BPF policies unless the
// policy explicitly allows fallback.
func NewPlatformEnhancedRecorder() EnhancedRecorder {
	return NewSourceEnhancedRecorder(NewLinuxProcEnhancedEventSource())
}

type unavailableEnhancedEventSource struct{}

func (unavailableEnhancedEventSource) Start(
	context.Context,
	EnhancedRecordingSession,
) (<-chan EnhancedEvent, func(context.Context) error, error) {
	return nil, nil, ErrEnhancedRecordingUnavailable
}
