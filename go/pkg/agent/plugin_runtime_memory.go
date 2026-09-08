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

package agent

import (
	"github.com/tetratelabs/wazero/api"
)

func readMemory(mod api.Module, ptr, size uint32) ([]byte, bool) {
	mem := mod.Memory()
	if mem == nil {
		return nil, false
	}
	data, ok := mem.Read(ptr, size)
	if !ok {
		return nil, false
	}
	out := make([]byte, len(data))
	copy(out, data)
	return out, true
}

func writeMemory(mod api.Module, ptr uint32, data []byte) bool {
	mem := mod.Memory()
	if mem == nil {
		return false
	}
	return mem.Write(ptr, data)
}
