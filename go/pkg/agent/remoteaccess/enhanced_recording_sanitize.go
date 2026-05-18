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
	"bytes"
	"strings"
)

func sanitizeKernelCString(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	if index := bytes.IndexByte(data, 0); index >= 0 {
		data = data[:index]
	}
	return sanitizeKernelString(string(data))
}

func sanitizeKernelString(value string) string {
	if value == "" {
		return ""
	}

	value = strings.ToValidUTF8(value, "?")

	return strings.Map(func(r rune) rune {
		if r < ' ' || r == 0x7f {
			return -1
		}
		return r
	}, value)
}
