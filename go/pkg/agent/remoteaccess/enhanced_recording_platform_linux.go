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

// PlatformEnhancedRecordingAvailable reports whether this host has the minimum
// Linux kernel surfaces needed for the future clean-room BPF collector.
func PlatformEnhancedRecordingAvailable() bool {
	return pathExists("/sys/fs/bpf") && (pathExists("/sys/kernel/tracing") || pathExists("/sys/kernel/debug/tracing"))
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// NewPlatformEnhancedRecorder returns the platform collector. The BPF source is
// intentionally unavailable until ServiceRadar-owned probes are implemented.
func NewPlatformEnhancedRecorder() EnhancedRecorder {
	return NewSourceEnhancedRecorder(unavailableEnhancedEventSource{})
}

type unavailableEnhancedEventSource struct{}

func (unavailableEnhancedEventSource) Start(
	context.Context,
	EnhancedRecordingSession,
) (<-chan EnhancedEvent, func(context.Context) error, error) {
	return nil, nil, ErrEnhancedRecordingUnavailable
}
