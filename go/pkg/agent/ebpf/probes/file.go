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

import "github.com/cilium/ebpf"

const (
	FileOpenatProgramName    = "sr_file_openat"
	FileAccessProgramName    = "sr_file_access"
	FileFAccessatProgramName = "sr_file_faccessat"
	FileEventsMap            = "sr_file_events"

	FilePathSize = 256

	FileOperationOpen   uint32 = 1
	FileOperationAccess uint32 = 2
)

type FileEvent struct {
	TimestampNS uint64
	PID         uint32
	TID         uint32
	UID         uint32
	GID         uint32
	Operation   uint32
	Flags       uint32
	Result      int32
	Path        [FilePathSize]byte
}

func LoadFileSpec() (*ebpf.CollectionSpec, error) {
	return loadFile()
}
