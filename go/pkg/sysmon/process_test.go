/*
 * Copyright 2026 Carver Automation Corporation.
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

package sysmon

import "testing"

func TestLimitProcessInfos(t *testing.T) {
	infos := []processInfo{
		{pid: 1},
		{pid: 2},
		{pid: 3},
	}

	limited := limitProcessInfos(infos, 2)
	if len(limited) != 2 {
		t.Fatalf("expected 2 process infos, got %d", len(limited))
	}
	if limited[0].pid != 1 || limited[1].pid != 2 {
		t.Fatalf("unexpected limited process infos: %#v", limited)
	}
}

func TestLimitProcessInfosKeepsAllForNonPositiveLimit(t *testing.T) {
	infos := []processInfo{{pid: 1}, {pid: 2}}

	limited := limitProcessInfos(infos, 0)
	if len(limited) != len(infos) {
		t.Fatalf("expected all process infos, got %d", len(limited))
	}
}
