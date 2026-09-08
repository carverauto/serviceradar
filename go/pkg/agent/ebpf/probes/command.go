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
	CommandProgramName = "sr_command_execve"
	CommandEventsMap   = "sr_command_events"

	CommandPathSize = 256
	CommandArgSize  = 128
	CommandMaxArgs  = 8
)

type CommandEvent struct {
	TimestampNS uint64
	PID         uint32
	TID         uint32
	UID         uint32
	GID         uint32
	Argc        uint32
	Result      int32
	Path        [CommandPathSize]byte
	Argv        [CommandMaxArgs][CommandArgSize]byte
}

func LoadCommandSpec() (*ebpf.CollectionSpec, error) {
	return loadCommand()
}
