//go:build !linux

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

// PlatformEnhancedRecordingAvailable reports whether host-event BPF tracing is
// available on this platform.
func PlatformEnhancedRecordingAvailable() bool {
	return false
}

// NewPlatformEnhancedRecorder returns nil on platforms without BPF support.
func NewPlatformEnhancedRecorder() EnhancedRecorder {
	return nil
}
